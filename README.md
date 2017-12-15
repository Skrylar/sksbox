# skSBOX

A pure-Nim implementation of Sean Barret's sBOX generic file container.

Does not include special tools to manage sBOX files, but allows you to easily read and write binary files based around a key-value concept.  sksbox makes heavy assumptions that your streams are seekable; sBOX does not require a file be easily streamable without seeking although certainly supports that kind of behavior.

Does include:

  - MIT license (very liberal.)
  - Nim documentation (commented code, as well as "nim doc" documentation.)
  - Full texinfo documentation (`cd docs && makeinfo --html sksbox.texi`.)
  - Undocumented bugs (maybe?)
