
import streams
import sksbox

const
  Signature = [0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8]

var writer: SboxWriter

var fs = new_file_stream("ex02.sbx", fm_write)
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
fs.close()
