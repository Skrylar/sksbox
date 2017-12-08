
import streams
import sksbox

const
  Signature = [0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8]

var writer: SboxWriter

var fs = new_file_stream("ex01.sbx", fm_write)
writer.open(fs)
writer.write_header(Signature)
writer.write_directory()
writer.write_tail()
fs.close()
