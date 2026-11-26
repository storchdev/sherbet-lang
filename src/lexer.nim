import diag
import span
import std/strutils
import std/strformat
import std/sugar
import std/sequtils

type
  TokenKind* = enum
    # Data
    tkID = "id"
    tkByte = "byte"
    tkInt = "int"
    tkFloat = "float"
    tkString = "str"
    tkFString = "fstr"
    tkDollar = "$"
    tkEOF = "EOF"
    # Whitespace
    tkNL = "NL"
    # Keywords
    tkFn = "fn"
    tkLet = "let"
    tkIf = "if"
    tkElse = "else"
    tkWhile = "while"
    tkFor = "for"
    tkIn = "in"
    tkBreak = "break"
    tkContinue = "continue"
    tkReturn = "return"
    tkMatch = "match"
    tkTry = "try"
    tkCatch = "catch"
    tkRaise = "raise"
    tkImport = "import"
    tkAs = "as"
    tkRecord = "record"
    tkType = "type"
    tkExtern = "extern"
    tkMemo = "memo"
    tkAnd = "and"
    tkOr = "or"
    tkNot = "not"
    tkIs = "is"
    tkNull = "null"
    tkTrue = "true"
    tkFalse = "false"
    # Operators (numerical)
    tkPlus = "+"
    tkMinus = "-"
    tkMul = "*"
    tkDiv = "/"
    tkFloorDiv = "~/"
    tkPower = "**"
    tkEq = "=="
    tkNeq = "!="
    tkGt = ">"
    tkGeq = ">="
    tkLt = "<"
    tkLeq = "<="
    tkMod = "%"
    tkAt = "@"
    tkBackslash = r"\"
    # Operators (bit)
    tkTilde = "~"
    tkAmp = "&"
    tkPipe = "|"
    tkCaret = "^"
    tkLShift = "<<"
    tkRShift = ">>"
    # Brackets
    tkLParen = "("
    tkRParen = ")"
    tkLBracket = "["
    tkRBracket = "]"
    tkDotBracket = ".["
    tkLBrace = "{"
    tkRBrace = "}"
    # Other symbols
    tkAssign = "="
    tkArrow = "->"
    tkFatArrow = "=>"
    tkRange = ".."
    tkRangeEq = "..="
    tkDot = "."
    tkComma = ","
    tkColon = ":"
    tkSemicolon = ";"
    tkBang = "!"
    tkQuestion = "?"
    tkQuestionDot = "?."
    # Operate + assign
    tkPlusEq = "+="
    tkMinusEq = "-="
    tkMulEq = "*="
    tkDivEq = "/="
    tkFloorDivEq = "~/="
    tkModEq = "%="
    tkPowerEq = "**="
    tkAtEq = "@="
    tkAmpEq = "&="
    tkPipeEq = "|="
    tkCaretEq = "^="
    tkLShiftEq = "<<="
    tkRShiftEq = ">>="

  Token* = object
    hasLineBreakBefore*: bool
    span*: Span
    case kind*: TokenKind
    of tkInt, tkFloat, tkString, tkID: text*: string
    of tkDollar: argIndex*: int
    of tkByte: byteVal*: uint8
    of tkFString: parts*: seq[FStringPart]
    else:
      discard

  FStringPartKind* = enum
    fsText
    fsExpr

  FStringPart* = object
    case kind*: FStringPartKind
    of fsText: text*: string
    of fsExpr:
      tokens*: seq[Token]
      spec*: seq[FStringPart]
      specSpan*: Span

type TestBlockKind* = enum
  testIn
  testOut

type TestBlock* = ref object
  kind*: TestBlockKind
  span*: Span
  path*: string

type Lexer = ref object
  tokens*: seq[Token]
  pragmas*: seq[Span]
  tests*: seq[TestBlock]
  bracketStack*: seq[TokenKind]
  file*: SherFile
  sink*: DiagnosticSink
  pos*: int
  prevTokenKind*: TokenKind
  hasLineBreak*: bool
  stringStartPos*: int # must be set when scanTokens(inFString=true)

type LexerResult* = ref object
  tokens*: seq[Token]
  pragmas*: seq[Span]
  tests*: seq[TestBlock]

type LexAbort = object of CatchableError

proc peek(lexer: Lexer, n: int = 0): char =
  if lexer.pos + n >= lexer.file.content.len:
    return '\0'

  return lexer.file.content[lexer.pos + n]

proc fail(lexer: Lexer, start: int, stop: int, message: string) {.noreturn.} =
  lexer.sink.reportError(
    initSpan(lexer.file.index, start, min(stop, lexer.file.content.len)),
    message,
    @[],
    @[],
  )
  raise newException(LexAbort, "")

proc emitToken(lexer: Lexer, token: Token, start: int) =
  var tcopy = token
  tcopy.span = initSpan(lexer.file.index, start, lexer.pos)
  tcopy.hasLineBreakBefore = lexer.hasLineBreak
  lexer.tokens.add(tcopy)
  lexer.prevTokenKind = tcopy.kind
  lexer.hasLineBreak = false

proc scanTokens(lexer: Lexer, inFString: bool)

proc scanFStringExpr(mainLexer: Lexer, stringStartPos: int): FStringPart =
  # Starts at {
  # Stops after }
  # Returns a FStringPart with kind fsExpr

  let lexer = mainLexer
  let subLexer = Lexer(
    file: lexer.file,
    sink: lexer.sink,
    pos: lexer.pos + 1, # consume the {
    prevTokenKind: tkNL,
    hasLineBreak: false,
    stringStartPos: stringStartPos,
  )
  subLexer.scanTokens(inFString = true)
  # TODO: {x=} form
  lexer.pos = subLexer.pos # update so we are about to consume } or :

  if lexer.peek() == '}':
    lexer.pos += 1
    return FStringPart(kind: fsExpr, tokens: subLexer.tokens, spec: @[])
  if lexer.peek() == ':':
    # spec loop: collect the chars until we hit {
    lexer.pos += 1
    let specStart = lexer.pos
    var specStop: int
    var specStr = ""
    var subExpr: FStringPart
    var spec: seq[FStringPart] = @[]

    while true:
      if lexer.pos >= lexer.file.content.len:
        lexer.fail(stringStartPos, lexer.pos, "unclosed string format")

      let c = lexer.peek()

      if c in ['\n', '"']:
        lexer.fail(
          stringStartPos, lexer.pos, "unexpected newline or quote in string format"
        )

      if c == '{':
        if specStr.len > 0:
          spec.add(FStringPart(kind: fsText, text: specStr))
          specStr = ""
        subExpr = scanFStringExpr(lexer, stringStartPos)
        spec.add(subExpr)
        continue

      if c == '}':
        # spec ends here
        if specStr.len > 0:
          spec.add(FStringPart(kind: fsText, text: specStr))
          specStr = ""
        specStop = lexer.pos # at the }
        lexer.pos += 1
        break

      specStr.add(c)
      lexer.pos += 1

    return FStringPart(
      kind: fsExpr,
      tokens: subLexer.tokens,
      spec: spec,
      specSpan: initSpan(lexer.file.index, specStart, specStop),
    )

  lexer.fail(stringStartPos, lexer.pos, "unclosed expression inside string")

proc scanEsc(lexer: Lexer, failStart: int = -1): char =
  ## This function expects lexer.pos to be on the backslash
  ## Returns successfully with lexer.pos on the next character

  var start = failStart
  if start == -1:
    start = lexer.pos

  let c = lexer.peek(1)
  var esc: char

  case c
  of 'n':
    esc = '\n'
    lexer.pos += 2
  of 't':
    esc = '\t'
    lexer.pos += 2
  of 'r':
    esc = '\r'
    lexer.pos += 2
  of '0':
    esc = char(0)
    lexer.pos += 2
  of '\\':
    esc = '\\'
    lexer.pos += 2
  of '"':
    esc = '"'
    lexer.pos += 2
  of '\'':
    esc = '\''
    lexer.pos += 2
  of 'x':
    if lexer.peek(2) notin HexDigits or lexer.peek(3) notin HexDigits:
      lexer.fail(start, lexer.pos + 4, "invalid hex escape")
    esc = char(parseHexInt(lexer.file.content[lexer.pos + 2 .. lexer.pos + 3]))
    lexer.pos += 4
  else:
    lexer.fail(start, lexer.pos + 2, "invalid escape sequence")

  return esc

proc scanString(lexer: Lexer) =
  # TODO: raw strings, dropping first newline and common indents in multiline
  let startPos = lexer.pos

  var multi: bool
  if lexer.peek(1) == '"' and lexer.peek(2) == '"':
    lexer.pos += 3
    multi = true
  else:
    lexer.pos += 1
    multi = false

  # invariant: if a fsText part is added to parts, the original str must be cleared
  var str = ""
  var parts: seq[FStringPart] = @[]
  var done = false

  while true:
    if lexer.pos >= lexer.file.content.len:
      lexer.fail(startPos, lexer.file.content.len, "unclosed string")

    if (lexer.peek() == '"' and not multi):
      done = true
      lexer.pos += 1
    if (lexer.peek(), lexer.peek(1), lexer.peek(2)) == ('"', '"', '"') and multi:
      done = true
      lexer.pos += 3

    if done:
      if str.len > 0:
        parts.add(FStringPart(kind: fsText, text: str))
        str = ""
      break

    if (lexer.peek(), lexer.peek(1)) == ('{', '{'):
      str.add('{')
      lexer.pos += 2
      continue

    if (lexer.peek(), lexer.peek(1)) == ('}', '}'):
      str.add('}')
      lexer.pos += 2
      continue

    if lexer.peek() == '}':
      lexer.fail(startPos, lexer.pos + 1, "unexpected '}' in string")

    if lexer.peek() == '\\':
      # always consume char after
      str.add(lexer.scanEsc(startPos))
      continue

    if lexer.peek() == '{':
      if str.len > 0:
        parts.add(FStringPart(kind: fsText, text: str))
        str = ""

      let part = scanFStringExpr(lexer, startPos)
      parts.add(part)
      continue

    if lexer.peek() == '\n' and not multi:
      lexer.fail(startPos, lexer.pos, "unclosed string")

    # ordinary characters
    str.add(lexer.file.content[lexer.pos])
    lexer.pos += 1

  if parts.len == 0: # empty str
    lexer.emitToken(Token(kind: tkString, text: ""), startPos)
  elif parts.len == 1 and parts[0].kind == fsText: # non f string
    lexer.emitToken(Token(kind: tkString, text: parts[0].text), startPos)
  else: # f string
    lexer.emitToken(Token(kind: tkFString, parts: parts), startPos)

proc getKeywordKind(word: string): TokenKind =
  return
    case word
    of "fn": tkFn
    of "let": tkLet
    of "if": tkIf
    of "else": tkElse
    of "while": tkWhile
    of "for": tkFor
    of "in": tkIn
    of "break": tkBreak
    of "continue": tkContinue
    of "return": tkReturn
    of "match": tkMatch
    of "try": tkTry
    of "catch": tkCatch
    of "raise": tkRaise
    of "import": tkImport
    of "as": tkAs
    of "record": tkRecord
    of "type": tkType
    of "extern": tkExtern
    of "memo": tkMemo
    of "and": tkAnd
    of "or": tkOr
    of "not": tkNot
    of "is": tkIs
    of "null": tkNull
    of "true": tkTrue
    of "false": tkFalse
    else: tkID

const LBrackets = {tkLBrace, tkLParen, tkLBracket, tkDotBracket}
const RBrackets = {tkRBrace, tkRParen, tkRBracket}
const BinaryOpTokens = {
  tkPlus, tkMinus, tkMul, tkDiv, tkFloorDiv, tkPower, tkEq, tkNeq, tkGt, tkGeq, tkLt,
  tkLeq, tkMod, tkAt, tkBackslash, tkAmp, tkPipe, tkCaret, tkLShift, tkRShift, tkRange,
  tkRangeEq, tkDot, tkQuestionDot, tkPlusEq, tkMinusEq, tkMulEq, tkDivEq, tkFloorDivEq,
  tkModEq, tkPowerEq, tkAtEq, tkAmpEq, tkPipeEq, tkCaretEq, tkLShiftEq, tkRShiftEq,
  tkAnd, tkOr, tkIn, tkIs,
}
# It makes sense to continue when a newline appears after these
const BeforeNLTokens =
  BinaryOpTokens - {tkRange, tkRangeEq} +
  {tkAssign, tkFatArrow, tkColon, tkComma, tkNL, tkNot} + LBrackets

# These drop the previous newline
const AfterNLTokens = {tkDot, tkDotBracket, tkQuestionDot, tkPipe, tkCatch, tkElse}

const TokenSpellings = [
  ("**=", tkPowerEq),
  ("~/=", tkFloorDivEq),
  ("<<=", tkLShiftEq),
  (">>=", tkRShiftEq),
  ("..=", tkRangeEq),
  ("~/", tkFloorDiv),
  ("**", tkPower),
  ("<<", tkLShift),
  (">>", tkRShift),
  ("..", tkRange),
  ("==", tkEq),
  ("!=", tkNeq),
  ("<=", tkLeq),
  (">=", tkGeq),
  ("->", tkArrow),
  ("=>", tkFatArrow),
  ("?.", tkQuestionDot),
  (".[", tkDotBracket),
  ("+=", tkPlusEq),
  ("-=", tkMinusEq),
  ("*=", tkMulEq),
  ("/=", tkDivEq),
  ("%=", tkModEq),
  ("@=", tkAtEq),
  ("&=", tkAmpEq),
  ("|=", tkPipeEq),
  ("^=", tkCaretEq),
  ("+", tkPlus),
  ("-", tkMinus),
  ("*", tkMul),
  ("/", tkDiv),
  ("~", tkTilde),
  ("%", tkMod),
  ("@", tkAt),
  (r"\", tkBackslash),
  ("&", tkAmp),
  ("|", tkPipe),
  ("^", tkCaret),
  ("!", tkBang),
  ("<", tkLt),
  (">", tkGt),
  (".", tkDot),
  ("=", tkAssign),
  ("?", tkQuestion),
  ("(", tkLParen),
  ("[", tkLBracket),
  ("{", tkLBrace),
  (")", tkRParen),
  ("]", tkRBracket),
  ("}", tkRBrace),
  (",", tkComma),
  (":", tkColon),
  (";", tkSemicolon),
]

proc getIdentStop(lexer: Lexer, offset: int = 0): int =
  ## Returns the index of the first non ident char starting from lexer.pos
  var i = lexer.pos + offset
  while i < lexer.file.content.len and lexer.file.content[i] in IdentChars:
    i += 1
  return i

proc getTrailingZeros(s: string): int =
  ## Returns number of trailing zeros at the end of s
  result = 0
  var i = s.len - 1
  while i >= 0 and s[i] == '0':
    result += 1
    i -= 1

proc scanTokens(lexer: Lexer, inFString: bool) =
  while true:
    if lexer.pos >= lexer.file.content.len:
      return

    let c = lexer.peek()
    if c == ' ' or c == '\t':
      lexer.pos += 1
      continue

    if c == '"':
      lexer.scanString()
      continue

    if c in ['}', ':'] and inFString and lexer.bracketStack.len == 0:
      return

    let start = lexer.pos

    # Names and keywords
    if c in IdentStartChars:
      lexer.pos += 1
      while true:
        let c1 = lexer.peek()
        if c1 notin IdentChars:
          break
        lexer.pos += 1

      let lexeme = lexer.file.content[start ..< lexer.pos]
      let kind = getKeywordKind(lexeme)
      if kind == tkID:
        lexer.emitToken(Token(kind: tkID, text: lexeme), start)
      else:
        lexer.emitToken(Token(kind: kind), start)
      continue

    if c == '\n':
      if inFString:
        # TODO: revisit when multiline str
        lexer.fail(
          lexer.stringStartPos, lexer.pos, "unexpected line break in string expression"
        )
      lexer.pos += 1
      # emit if both are true:
      # no innermost bracket OR innermost bracket is a {
      # prev token is not a continuation (allowed before a NL)
      if (lexer.bracketStack.len == 0 or lexer.bracketStack[^1] == tkLBrace) and
          lexer.prevTokenKind notin BeforeNLTokens:
        lexer.emitToken(Token(kind: tkNL), start)

      lexer.hasLineBreak = true
      continue

    # match comments now so it doesnt get picked up by `/` later
    if c == '/' and lexer.peek(1) == '/':
      lexer.pos += 2
      while lexer.peek() != '\n' and lexer.pos < lexer.file.content.len:
        lexer.pos += 1
      continue

    # numbers

    if c in Digits:
      let c1 = lexer.peek(1)
      var base = 10
      var shift = 0
      var allowedDigits = Digits

      if c == '0':
        case c1
        of 'x':
          base = 16
          shift = 2
          allowedDigits = HexDigits
        of 'o':
          base = 8
          shift = 2
          allowedDigits = Digits - {'8', '9'}
        of 'b':
          base = 2
          shift = 2
          allowedDigits = {'0', '1'}
        of 'X', 'O', 'B':
          lexer.fail(
            start,
            lexer.getIdentStop(2),
            &"base prefix must be lowercase: '0{c1.toLowerAscii()}'",
          )
        else:
          discard

      lexer.pos += shift
      var point = false # whether we have seen a decimal point
      var e = false # whether we have seen an e

      # make sure theres at least one digit in the start
      if shift > 0 and lexer.peek() notin allowedDigits:
        lexer.fail(start, start + 2, &"expected digits after '0{c1}'")

      while true:
        if lexer.pos >= lexer.file.content.len:
          break

        let d = lexer.peek()

        if d == '_':
          if lexer.peek(-1) notin allowedDigits or lexer.peek(1) notin allowedDigits:
            lexer.fail(start, lexer.getIdentStop(), "'_' must be between digits")
          lexer.pos += 1
          continue

        if d == '.':
          if base != 10 or point or e or lexer.prevTokenKind in {tkDot, tkQuestionDot}:
            break

          if lexer.peek(1) notin allowedDigits:
            break

          point = true
          lexer.pos += 1
          continue

        if d in {'e', 'E'} and base == 10:
          if e or lexer.prevTokenKind in {tkDot, tkQuestionDot}:
            let stop = lexer.getIdentStop()
            let suff = lexer.file.content[lexer.pos ..< stop]
            lexer.fail(
              start, lexer.getIdentStop(1), &"invalid suffix '{suff}' on number"
            )
          e = true

          if lexer.peek(1) in Digits:
            lexer.pos += 1
          elif lexer.peek(1) in {'+', '-'}:
            if lexer.peek(2) notin allowedDigits:
              lexer.fail(start, lexer.getIdentStop(2), "expected digits in exponent")
            lexer.pos += 2
          else:
            lexer.fail(start, lexer.getIdentStop(1), "expected digits in exponent")

          continue

        if d in allowedDigits:
          lexer.pos += 1
          continue

        if d in Letters:
          let stop = lexer.getIdentStop()
          let suff = lexer.file.content[lexer.pos ..< stop]
          lexer.fail(start, stop, &"invalid suffix '{suff}' on number")

        if d in Digits:
          let adj =
            case base
            of 2: "binary"
            of 8: "octal"
            else: "unknown"
          lexer.fail(
            start, lexer.getIdentStop(), &"invalid digit '{d}' in {adj} literal"
          )

        break # ending the literal

      let lexeme = lexer.file.content[start ..< lexer.pos].replace("_", "")

      if base == 10 and len(lexeme) > 1 and lexeme[0] == '0' and lexeme[1] in Digits:
        lexer.fail(
          start, lexer.pos, "leading zeros are not allowed; use '0o' for octal"
        )

      # decide whether to emit a Int or Float

      var exp = 0 # exponent value
      var z = 0 # number of trailing zeros
      var f = 0 # number of fraction digits

      if e:
        let b = lexeme.find({'e', 'E'})
        let mantissa = lexeme[0 ..< b]
        z = getTrailingZeros(mantissa.replace(".", ""))
        let a = mantissa.find('.')
        if a >= 0:
          f = mantissa.len - a - 1

        try:
          exp = parseInt(lexeme[b + 1 ..< lexeme.len])
        except ValueError:
          if lexeme[b + 1] == '-':
            lexer.emitToken(Token(kind: tkFloat, text: lexeme), start)
          else:
            lexer.emitToken(Token(kind: tkInt, text: lexeme), start)
          continue

        if exp - f + z >= 0:
          lexer.emitToken(Token(kind: tkInt, text: lexeme), start)
        else:
          lexer.emitToken(Token(kind: tkFloat, text: lexeme), start)
      elif point:
        lexer.emitToken(Token(kind: tkFloat, text: lexeme), start)
      else:
        lexer.emitToken(Token(kind: tkInt, text: lexeme), start)

      continue

    if c == '\'':
      let c1 = lexer.peek(1)
      if c1 == '\'':
        lexer.fail(start, start + 2, "empty byte literal")
      if c1 == '\n' or lexer.pos + 1 >= lexer.file.content.len:
        # line break or EOF
        lexer.fail(start, start + 1, "unclosed byte literal")

      var b: uint8

      lexer.pos += 1
      if c1 == '\\':
        let esc = lexer.scanEsc(start)
        b = esc.uint8
      else:
        b = c1.uint8
        lexer.pos += 1

      if lexer.peek() != '\'':
        var i = lexer.pos
        while true:
          if i >= lexer.file.content.len or lexer.file.content[i] == '\n':
            lexer.fail(start, lexer.pos, "unclosed byte literal")
          if lexer.file.content[i] == '\'':
            lexer.fail(start, i + 1, "byte literal holds more than one byte")
          i += 1

      lexer.pos += 1
      lexer.emitToken(Token(kind: tkByte, byteVal: b), start)
      continue

    var match = false
    for str, tk in TokenSpellings.items:
      if strutils.continuesWith(lexer.file.content, str, lexer.pos):
        # must be the longest one

        lexer.pos += str.len

        # handle bracket stack
        if tk in LBrackets:
          lexer.bracketStack.add(tk)
        elif tk in RBrackets:
          if lexer.bracketStack.len == 0:
            lexer.fail(start, lexer.pos, &"unmatched {c}")
          discard lexer.bracketStack.pop()

        lexer.emitToken(Token(kind: tk), start)
        match = true
        break

    if match:
      continue

    # TODO:other tokens!

    # escape hatch so it doesnt infinite loop on unsupported shit
    lexer.fail(lexer.pos, lexer.pos + 1, "unsupported token start character")

proc dropPrevNLTokens(lexer: Lexer) =
  var newTokens: seq[Token] = @[]
  for i, t in lexer.tokens:
    if t.kind == tkNL and i < lexer.tokens.len - 1:
      if lexer.tokens[i + 1].kind in AfterNLTokens:
        continue
    newTokens.add(t)
  lexer.tokens = newTokens

proc scan*(file: SherFile, sink: DiagnosticSink): LexerResult =
  var lexer =
    Lexer(file: file, sink: sink, pos: 0, prevTokenKind: tkNL, hasLineBreak: false)

  try:
    lexer.scanTokens(inFString = false)
  except LexAbort:
    discard # fail gracefully, sink already has errors 

  lexer.pos = file.content.len
  lexer.emitToken(Token(kind: tkEOF), start = file.content.len)

  # Hybrid approach: we already "drop" NLs that follow tokens in the main loop
  # because it doesn't require lookahead
  lexer.dropPrevNLTokens()

  return LexerResult(tokens: lexer.tokens, pragmas: lexer.pragmas, tests: lexer.tests)

proc `$`*(f: FStringPart): string

proc `$`*(t: Token): string =
  if t.kind in {tkID, tkInt, tkFloat}:
    return &"{$t.kind}:{t.text}"

  if t.kind == tkString:
    result = &"str:"
    addQuoted(result, t.text)
    return

  if t.kind == tkByte:
    return &"byte:{t.byteVal}"

  if t.kind == tkDollar:
    return &"${t.argIndex}"

  if t.kind == tkFSTring:
    let parts = t.parts.map((s) => $s).join(" ")
    return &"fstr[ {parts} ]"

  return $t.kind

    # of tkInt, tkFloat, tkString, tkID: text*: string
    # of tkDollar: argIndex*: int
    # of tkByte: byteVal*: uint8
    # of tkFString: parts*: seq[FStringPart]

proc `$`*(f: FStringPart): string =
  if f.kind == fsText:
    addQuoted(result, f.text)
  else:
    let ttext = f.tokens.join(" ")
    if f.spec.len > 0:
      let stext = f.spec.map((s) => $s).join(" ")
      result = &"{{ {ttext}:{stext} }}"
    else:
      result = &"{{ {ttext} }}"

proc dump*(tokens: openArray[Token]): string =
  result = ""
  for i, t in tokens:
    result &= $t
    if t.kind == tkNL:
      result &= "\n"
    elif i < tokens.len - 1:
      result &= " "
    else:
      result &= "\n"
