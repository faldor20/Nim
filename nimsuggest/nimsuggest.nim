#
#
#           The Nim Compiler
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import compiler/renderer
import tables
import times

import setup
import utils
import emacs
import execution
import repl

import communication
import consts
## Nimsuggest is a tool that helps to give editors IDE like capabilities.

when not defined(nimcore):
  {.error: "nimcore MUST be defined for Nim's core tooling".}

import strutils, os, parseopt, parseutils,  net 
# Do NOT import suggest. It will lead to weird bugs with
# suggestionResultHook, because suggest.nim is included by sigmatch.
# So we import that one instead.

import compiler/options
import compiler/commands
import compiler/modules
import compiler/passes
import compiler/passaux
import compiler/msgs
import compiler/idents
import compiler/modulegraphs
import compiler/lineinfos
import compiler/cmdlinehelper
import compiler/pathutils
import compiler/condsyms

when defined(nimPreviewSlimSystem):
  import std/typedthreads

when defined(windows):
  import winlean
else:
  import posix



proc parseQuoted*(cmd: string; outp: var string; start: int): int =
  var i = start
  i += skipWhitespace(cmd, i)
  if i < cmd.len and cmd[i] == '"':
    i += parseUntil(cmd, outp, '"', i+1)+2
  else:
    i += parseUntil(cmd, outp, seps, i)
  result = i



proc execCmd(cmd: string; graph: ModuleGraph; cachedMsgs: CachedMsgs) =
  let conf = graph.config

  template sentinel() =
    # send sentinel for the input reading thread:
    results.send(Suggest(section: ideNone))

  template toggle(sw) =
    if sw in conf.globalOptions:
      excl(conf.globalOptions, sw)
    else:
      incl(conf.globalOptions, sw)
    sentinel()
    return

  template err() =
    echo Help
    sentinel()
    return

  var opc = ""
  var i = parseIdent(cmd, opc, 0)
  case opc.normalize
  of "sug": conf.ideCmd = ideSug
  of "con": conf.ideCmd = ideCon
  of "def": conf.ideCmd = ideDef
  of "use": conf.ideCmd = ideUse
  of "dus": conf.ideCmd = ideDus
  of "mod": conf.ideCmd = ideMod
  of "chk": conf.ideCmd = ideChk
  of "highlight": conf.ideCmd = ideHighlight
  of "outline": conf.ideCmd = ideOutline
  of "quit":
    sentinel()
    quit()
  of "debug": toggle optIdeDebug
  of "terse": toggle optIdeTerse
  of "known": conf.ideCmd = ideKnown
  of "project": conf.ideCmd = ideProject
  of "changed": conf.ideCmd = ideChanged
  of "globalsymbols": conf.ideCmd = ideGlobalSymbols
  of "declaration": conf.ideCmd = ideDeclaration
  of "expand": conf.ideCmd = ideExpand
  of "chkfile": conf.ideCmd = ideChkFile
  of "recompile": conf.ideCmd = ideRecompile
  of "type": conf.ideCmd = ideType
  else: err()
  var dirtyfile = ""
  var orig = ""
  i += skipWhitespace(cmd, i)
  if i < cmd.len and cmd[i] in {'0'..'9'}:
    orig = string conf.projectFull
  else:
    i = parseQuoted(cmd, orig, i)
    if i < cmd.len and cmd[i] == ';':
      i = parseQuoted(cmd, dirtyfile, i+1)
    i += skipWhile(cmd, seps, i)
  var line = 0
  var col = -1
  i += parseInt(cmd, line, i)
  i += skipWhile(cmd, seps, i)
  i += parseInt(cmd, col, i)
  let tag = substr(cmd, i)

  if conf.ideCmd == ideKnown:
    results.send(Suggest(section: ideKnown, quality: ord(fileInfoKnown(conf, AbsoluteFile orig))))
  elif conf.ideCmd == ideProject:
    results.send(Suggest(section: ideProject, filePath: string conf.projectFull))
  else:
    if conf.ideCmd == ideChk:
      for cm in cachedMsgs: errorHook(conf, cm.info, cm.msg, cm.sev)
    execute(conf.ideCmd, AbsoluteFile orig, AbsoluteFile dirtyfile, line, col, tag, graph)
  sentinel()


proc mainThread(graph: ModuleGraph) =
  let conf = graph.config
  myLog "searchPaths: "
  for it in conf.searchPaths:
    myLog("  " & it.string)

  proc wrHook(line: string) {.closure.} =
    if gMode == mepc:
      if gLogging: log(line)
    else:
      writelnToChannel(line)

  conf.writelnHook = wrHook
  conf.suggestionResultHook = sugResultHook
  graph.doStopCompile = proc (): bool = requests.peek() > 0
  var idle = 0
  var cachedMsgs: CachedMsgs = @[]
  while true:
    let (hasData, req) = requests.tryRecv()
    if hasData:
      conf.writelnHook = wrHook
      conf.suggestionResultHook = sugResultHook
      execCmd(req, graph, cachedMsgs)
      idle = 0
    else:
      os.sleep 250
      idle += 1
    if idle == 20 and gRefresh and conf.suggestVersion != 3:
      # we use some nimsuggest activity to enable a lazy recompile:
      conf.ideCmd = ideChk
      conf.writelnHook = proc (s: string) = discard
      cachedMsgs.setLen 0
      conf.structuredErrorHook = proc (conf: ConfigRef; info: TLineInfo; msg: string; sev: Severity) =
        cachedMsgs.add(CachedMsg(info: info, msg: msg, sev: sev))
      conf.suggestionResultHook = proc (s: Suggest) = discard
      recompileFullProject(graph)

var
  inputThread: Thread[ThreadParams]

proc mainCommand(graph: ModuleGraph) =
  let conf = graph.config
  clearPasses(graph)
  registerPass graph, verbosePass
  registerPass graph, semPass
  conf.setCmd cmdIdeTools
  defineSymbol(conf.symbols, $conf.backend)
  wantMainModule(conf)

  if not fileExists(conf.projectFull):
    quit "cannot find file: " & conf.projectFull.string

  add(conf.searchPaths, conf.libpath)

  conf.setErrorMaxHighMaybe # honor --errorMax even if it may not make sense here
  # do not print errors, but log them
  conf.writelnHook = proc (msg: string) = discard

  if graph.config.suggestVersion == 3:
    graph.config.structuredErrorHook = proc (conf: ConfigRef; info: TLineInfo; msg: string; sev: Severity) =
      let suggest = Suggest(section: ideChk, filePath: toFullPath(conf, info),
        line: toLinenumber(info), column: toColumn(info), doc: msg, forth: $sev)
      graph.suggestErrors.mgetOrPut(info.fileIndex, @[]).add suggest

  # compile the project before showing any input so that we already
  # can answer questions right away:
  benchmark "Initial compilation":
    compileProject(graph)

  open(requests)
  open(results)

  case gMode
  of mstdin: createThread(inputThread, replStdin, (gPort, gAddress))
  of mtcp: createThread(inputThread, replTcp, (gPort, gAddress))
  of mepc: createThread(inputThread, replEpc, (gPort, gAddress))
  of mcmdsug: createThread(inputThread, replCmdline,
                            (gPort, "sug \"" & conf.projectFull.string & "\":" & gAddress))
  of mcmdcon: createThread(inputThread, replCmdline,
                            (gPort, "con \"" & conf.projectFull.string & "\":" & gAddress))
  mainThread(graph)
  joinThread(inputThread)
  close(requests)
  close(results)

proc processCmdLine*(pass: TCmdLinePass, cmd: string; conf: ConfigRef) =
  var p = parseopt.initOptParser(cmd)
  var findProject = false
  while true:
    parseopt.next(p)
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      case p.key.normalize
      of "help", "h":
        stdout.writeLine(Usage)
        quit()
      of "autobind":
        gMode = mtcp
        gAutoBind = true
      of "port":
        gPort = parseInt(p.val).Port
        gMode = mtcp
      of "address":
        gAddress = p.val
        gMode = mtcp
      of "stdin": gMode = mstdin
      of "cmdsug":
        gMode = mcmdsug
        gAddress = p.val
        incl(conf.globalOptions, optIdeDebug)
      of "cmdcon":
        gMode = mcmdcon
        gAddress = p.val
        incl(conf.globalOptions, optIdeDebug)
      of "epc":
        gMode = mepc
        conf.verbosity = 0          # Port number gotta be first.
      of "debug": incl(conf.globalOptions, optIdeDebug)
      of "v1": conf.suggestVersion = 1
      of "v2": conf.suggestVersion = 0
      of "v3": conf.suggestVersion = 3
      of "tester":
        gMode = mstdin
        gEmitEof = true
        gRefresh = false
      of "log": gLogging = true
      of "refresh":
        if p.val.len > 0:
          gRefresh = parseBool(p.val)
        else:
          gRefresh = true
      of "maxresults":
        conf.suggestMaxResults = parseInt(p.val)
      of "find":
        findProject = true
      else: processSwitch(pass, p, conf)
    of cmdArgument:
      let a = unixToNativePath(p.key)
      if dirExists(a) and not fileExists(a.addFileExt("nim")):
        conf.projectName = findProjectNimFile(conf, a)
        # don't make it worse, report the error the old way:
        if conf.projectName.len == 0: conf.projectName = a
      else:
        if findProject:
          conf.projectName = findProjectNimFile(conf, a.parentDir())
          if conf.projectName.len == 0:
            conf.projectName = a
        else:
          conf.projectName = a
      # if processArgument(pass, p, argsCount): break

proc handleCmdLine(cache: IdentCache; conf: ConfigRef) =
  let self = NimProg(
    suggestMode: true,
    processCmdLine: processCmdLine
  )
  self.initDefinesProg(conf, "nimsuggest")

  if paramCount() == 0:
    stdout.writeLine(Usage)
    return

  self.processCmdLineAndProjectPath(conf)

  if gMode != mstdin:
    conf.writelnHook = proc (msg: string) = discard
  # Find Nim's prefix dir.
  let binaryPath = findExe("nim")
  if binaryPath == "":
    raise newException(IOError,
        "Cannot find Nim standard library: Nim compiler not in PATH")
  conf.prefixDir = AbsoluteDir binaryPath.splitPath().head.parentDir()
  if not dirExists(conf.prefixDir / RelativeDir"lib"):
    conf.prefixDir = AbsoluteDir""

  #msgs.writelnHook = proc (line: string) = log(line)
  myLog("START " & conf.projectFull.string)

  var graph = newModuleGraph(cache, conf)
  if self.loadConfigsAndProcessCmdLine(cache, conf, graph):
    mainCommand(graph)

when isMainModule:
  handleCmdLine(newIdentCache(), newConfigRef())
else:
 import testInterface
 export testInterface