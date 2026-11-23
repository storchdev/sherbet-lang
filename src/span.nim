import std/algorithm

type Span* = object
  fileIndex*: int
  start*: int
  stop*: int

type SherFile* = ref object
  index*: int
  name*: string
  content*: string
  lineOffsets*: seq[int]

type FileList* = ref object
  files*: seq[SherFile]

proc addFile*(self: FileList, fileName: string): SherFile =
  let content = readFile(fileName)
  var offsets: seq[int] = @[0]

  for i, c in content:
    if c == '\n':
      offsets.add(i + 1)

  result = SherFile(
    index: self.files.len, name: fileName, content: content, lineOffsets: offsets
  )
  self.files.add(result)

proc getSpanPos*(self: FileList, span: Span): (int, int) =
  let augFile = self.files[span.fileIndex]
  let row = upperBound(augFile.lineOffsets, span.start) - 1
  let startCol = span.start - augFile.lineOffsets[row]
  result = (row, startCol)

proc initSpan*(fileIndex: int, start: int, stop: int): Span =
  result = Span(fileIndex: fileIndex, start: start, stop: stop)

proc initFileList*(): FileList =
  result = FileList(files: @[])
