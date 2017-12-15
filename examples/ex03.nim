
import streams
import sksbox

const
  Signature = [0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8]

proc filesize(filename: string): int =
  ## Calculates the size of a file, because Nim streams are too anemic :/
  var f: File
  if open(f, filename, fm_read) == false: return 0
  setfilepos(f, 0, fsp_end)
  result = getfilepos(f).int
  f.close()

block create_file:              # create the file we're going to read later
  var fs = new_file_stream("ex03.sbx", fm_write)
  var writer: SboxWriter

  writer.open(fs)
  writer.write_header(Signature)

  writer.open_block("memes")
  fs.writeln("`All toasters, toast toast.' -- Mario.")
  writer.close_block()

  writer.open_block("truth")
  fs.writeln("42.")
  writer.close_block("truth")

  writer.write_directory()
  writer.write_tail()
  fs.flush()
  fs.close()

block read_file:
  var fs = new_file_stream("ex03.sbx", fm_read)
  var signature: UserSignature  # we're going to end up reading this
  var reader: SboxReader
  fs.set_position(0)            # go back to file start
  reader.open(fs)               # prepare the reader
  if reader.read_header(signature, filesize("ex03.sbx")) == false:
    echo "Failed to read header :("
    break read_file
  var where, len: DirectoryFieldType
  var name: string
  while reader.read_next(where, len, name):
    echo name, "::(", where, ",", len, ")"
  fs.close()
