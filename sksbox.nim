# Copyright 2017 Joshua A. Cearley
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

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

  SboxReader* = object
    diroff_location*: DiroffLocation # Where is diroff?
    dirsize*: DirectoryFieldType     # Size of directory remaining.
    diroffbmk: int                   # Where are we in the directory?
    s: Stream                        # Where we read from.

const
  SboxSignature* = [115'u8, 98'u8, 48'u8, 88'u8]
  DefaultMaxNameLength = 1024

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

proc open*(self: var SboxReader; stream: Stream) =
  self.dirsize = 0
  self.s = stream

proc read_header*(self: var SboxReader; signature: var UserSignature; eof: int = 0): bool =
  ## Attempts to read an sbox file header.  The file signature is
  ## written to ``signature''.  ``eof'' is a marker for the end of the
  ## sbox stream.  sbox files which store directory offsets at the end
  ## of the file require seeking to the end, which is interpreted as
  ## ``eof'' unless ``eof'' is zero.  You should set ``eof'' to
  ## ex. the length of a file, or at least the end of where an sbox is
  ## stored within a larger stream, as the tail offset starts usually
  ## eight bytes prior to eof.  If ``eof'' is zero and the directory
  ## offset is written at the tail, an exception is thrown as we won't
  ## know where to look.  If possible, the underlying stream will be
  ## left at the beginning of the directory.

  # TODO base seeking off byte we start at, so we have a fully position independent reader; currently we assume the end is possibly unknown yet the start is always zero
  var sbox: array[0..SboxSignature.high, uint8]
  # read file signature
  var readlen = self.s.readdata(addr signature[0], UserSignature.high+1)
  if readlen < UserSignature.high:
    writeStackTrace()
    return false
  # read sbox signature
  readlen = self.s.readdata(addr sbox[0], SboxSignature.len)
  if readlen < SboxSignature.high:
    writeStackTrace()
    return false
  # ensure sbox signature is valid
  for i in 0..sbox.high:
    if sbox[i] != SboxSignature[i]:
      writeStackTrace()
      return false
  # now read diroff
  var diroff: DirectoryFieldType
  readlen = self.s.readdata(addr diroff, DirectoryFieldType.sizeof)
  if readlen < DirectoryFieldType.sizeof:
    writeStackTrace()
    return false
  # figure out if this is known to the start, or end, of the sbox file
  if diroff == 0: self.diroff_location = DiroffAtEnd
  else: self.diroff_location = DiroffAtStart
  # ok, now we must handle finding the directory
  case self.diroff_location:
    of DiroffAtStart:           # we already read it
      discard
    of DiroffAtEnd:             # have to seek and find it
      assert eof > 0            # TODO proper exception
      self.s.set_position(eof - SboxSignature.len) # seek to tail
      # check that sbox tag is here at the end
      readlen = self.s.readdata(addr sbox[0], SboxSignature.len)
      if readlen < SboxSignature.len:
        writeStackTrace()
        return false
      for i in 0..sbox.high:
        if sbox[i] != SboxSignature[i]:
          writeStackTrace()
          return false
      # now find diroff
      self.s.set_position(eof - (DirectoryFieldType.sizeof.int + SboxSignature.len))
      readlen = self.s.readdata(addr diroff, DirectoryFieldType.sizeof)
      if readlen < DirectoryFieldType.sizeof:
        writeStackTrace()
        return false
  # seek to directory and we are done!
  self.s.set_position(diroff.int)
  # check that sbox tag is here at the directory
  readlen = self.s.readdata(addr sbox[0], SboxSignature.len)
  if readlen < SboxSignature.len:
    writeStackTrace()
    return false
  for i in 0..sbox.high:
    if sbox[i] != SboxSignature[i]:
      writeStackTrace()
      return false
  # read dir
  readlen = self.s.readdata(addr diroff, DirectoryFieldType.sizeof)
  if readlen < DirectoryFieldType.sizeof:
    writeStackTrace()
    return false
  self.dirsize = diroff
  self.diroffbmk = self.s.get_position()
  # success
  return true

proc read_next*(self: var SboxReader; data_start, data_len: out DirectoryFieldType; name: out string; max_name_length: int = DefaultMaxNameLength): bool =
  # fail if remaining size is smaller than an entry even can be
  if self.dirsize < (DirectoryFieldType.sizeof.int * 3): return false
  # move to directory entry
  self.s.set_position(self.diroffbmk)

  # read length of entries
  var value_offset, value_size, name_size: DirectoryFieldType
  if self.s.read_data(addr value_offset, DirectoryFieldType.sizeof) < DirectoryFieldType.sizeof.int: return false
  if self.s.read_data(addr value_size, DirectoryFieldType.sizeof) < DirectoryFieldType.sizeof.int: return false
  if self.s.read_data(addr name_size, DirectoryFieldType.sizeof) < DirectoryFieldType.sizeof.int: return false

  # export data information
  data_start = value_offset
  data_len = value_size

  # export the name, reading it if we have to
  if name_size < 1 or max_name_length < 1:
    name = nil                  # no name to export
  else:                         # get as much as we can
    assert(max_name_length >= 1)
    var out_name = new_string(min(max_name_length, name_size.int))
    discard self.s.read_data(cast[pointer](addr out_name[0]), name_size.int)
    name = out_name

  # seek next padded space
  let padding = self.s.get_position %% 4
  self.s.set_position(self.s.get_position + padding)

  # book keeping
  let here = self.s.get_position()
  dec self.dirsize, (here - self.diroffbmk)
  self.diroffbmk = here
  return true
