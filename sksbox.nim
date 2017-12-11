
import streams

type
  UserSignature* = array[0..15, uint8] ## Can be anything you like.
  DirectoryFieldType* = uint32         ## In case you want an sBOX64 later.

  DiroffLocation* = enum
    DiroffAtStart = 0 ## Directory is at the beginning of the sBOX file.
    DiroffAtEnd       ## Directory is at the end of the sBOX file.

  DirectoryEntry* = object
    value_offset*: DirectoryFieldType ## Which byte starts the value in this file.
    value_size*: DirectoryFieldType ## How many bytes does the value occupy?
    name_size*: DirectoryFieldType ## How many bytes does the name occupy?
    name_offset*: DirectoryFieldType ## Which byte starts the name in this file.
    name*: string                    ## Stores the name (ex. for writing.)

  # NB: name offset is a hack because we don't know how downstream
  # wants to handle names; they might want to do something cheeky
  # (this is a low level format afterall), limit value length and
  # insert in a crit-bit or a hash or anything.

  SboxWriter* = object
    diroff_location*: DiroffLocation # Where to write diroff?
    entries: seq[DirectoryEntry]  # store entries that have been opened.
    entry_stack: seq[int]    # Track open but not yet closed entries.
    s: Stream                # Where the writer writes to.
    diroffbmk: int           # Position that diroff can be written to.
    diroff: int              # Where DID we actually write the offset?

const
  SboxSignature* = [115'u8, 98'u8, 48'u8, 88'u8]

proc open*(self: var SboxWriter; s: Stream) =
  if self.entries == nil:
    newseq(self.entries, 0)
  else:
    setlen(self.entries, 0)

  if self.entry_stack == nil:
    newseq(self.entry_stack, 0)
  else:
    setlen(self.entry_stack, 0)

  self.diroffbmk = 0
  self.diroff = 0
  self.s = s

proc write_header*(self: var SboxWriter; signature: UserSignature) =
  ## Writes the header for this sBOX file, notes where the directory
  ## offset should go (if diroff is to be written at file start) and
  ## writes a blank diroff in case it is written at the file's end.
  self.s.write_data(unsafeAddr signature[0], signature.len)
  for b in SboxSignature: self.s.write(b)
  self.diroffbmk = self.s.get_position
  self.s.write(0.DirectoryFieldType)

proc open_block*(self: var SboxWriter; blockname: string) =
  ## Informs the writer you are starting a new block.  Directory
  ## information is created in memory for the block, and finished on
  ## the next call to close_block.

  var header = DirectoryEntry()
  header.value_offset = self.s.get_position().DirectoryFieldType
  header.name = blockname

  # book-keeping
  self.entry_stack.add self.entries.len
  self.entries.add header

proc close_block*(self: var SboxWriter; blockname: string = nil) =
  ## Informs the writer you have finished writing the most recent
  ## block.  Directory information is updated.  If you supply a
  ## blockname here, it will be checked against the most recent block
  ## on the stack and an exception is thrown if they do not match.  If
  ## no block name is given, the topmost block is closed without
  ## question.

  if self.entry_stack.len < 1: return # TODO underflow exception
  let latest = self.entry_stack.pop   # retrieve ID of latest block
  # optional sanity testing
  if blockname != nil:
    assert blockname == self.entries[latest].name # TODO exception
  # update directory information
  self.entries[latest].value_size = self.s.get_position().DirectoryFieldType - self.entries[latest].value_offset

proc pad_stream(self: var SboxWriter) =
  let padding = self.s.get_position %% 4
  for i in 0..<padding:
    self.s.write(0'u8)

proc write_directory*(self: var SboxWriter) =
  self.pad_stream
  self.diroff = self.s.get_position

  for b in SboxSignature: self.s.write(b)
  self.s.write(0.DirectoryFieldType) # empty directory size, for now

  for entry in self.entries:
    var n = entry.name
    self.s.write(entry.value_offset)
    self.s.write(entry.value_size)
    self.s.write(entry.name.len.DirectoryFieldType)
    self.s.write_data(unsafeAddr n[0], n.len)
    self.pad_stream

  self.pad_stream               # just in case
  let bmk = self.s.get_position
  let dirsize = bmk - self.diroff
  self.s.set_position self.diroff + SboxSignature.len
  self.s.write(dirsize.DirectoryFieldType)
  self.s.set_position bmk

proc write_tail*(self: var SboxWriter) =
  self.pad_stream        # make sure tail ends on a four byte boundary
  assert(self.diroff > 0)       # make sure you didn't do a bad
  # maybe write diroff location
  if self.diroff_location == DiroffAtEnd:
    self.s.write(self.diroff.uint32) # write it
  else:                              # otherwise seek back and write there
    self.s.write(0.DirectoryFieldType)
    let bmk = self.s.get_position()
    self.s.set_position(self.diroffbmk)
    self.s.write(self.diroff.DirectoryFieldType)
    self.s.set_position(bmk)
  # write tail signature
  for b in SboxSignature: self.s.write(b)
