## VAR-004: the environments a script gives to a step (common/stepenv.nim): the core checks them against the deny-list, the shim reads the step's own. Pure.
import std/[unittest, json, strutils]
import common/stepenv

suite "VAR-004 the env in a step's options":
  test "VAR-004 envOf reads the pairs under a key, sorted, and nothing from a damaged or missing options text":
    let o = """{"env":{"B":"2","A":"1"},"step_env":{"Z":"z"},"timeout":5}"""
    check envOf(o, "env") == @[("A", "1"), ("B", "2")]
    check envOf(o, "step_env") == @[("Z", "z")]
    check envOf("", "env").len == 0 and envOf("{broken", "env").len == 0 and envOf("""{"env":[1]}""", "env").len == 0
  test "VAR-004 a name a step may not set (STO-004) is refused by checkEnv and left out by envOf":
    for name in ["PATH", "LD_PRELOAD", "CICD_ENV", "BASH_ENV", "HOME"]:
      let o = "{\"env\":{\"" & name & "\":\"x\"}}"
      check checkEnv(o).len > 0 and name in checkEnv(o)
      check envOf(o, "env").len == 0
    check checkEnv("""{"step_env":{"PATH":"x"}}""").len > 0
  test "VAR-004 an ordinary environment is accepted, one with a bad name or a value that is too long is not":
    check checkEnv("""{"env":{"REGION":"eu"},"step_env":{"X_1":"y"}}""") == ""
    check checkEnv("") == "" and checkEnv("{broken") == "" and checkEnv("""{"secrets":["A"]}""") == ""
    check checkEnv("""{"env":{"lower":"x"}}""").len > 0
    check checkEnv("{\"env\":{\"A\":\"" & repeat('x', 9000) & "\"}}").len > 0
    check checkEnv("""{"env":{"A":1}}""").len > 0
