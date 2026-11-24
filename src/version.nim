import std/strutils

func parseVersion(nimble: string): string =
  for line in nimble.splitLines():
    let entry = line.split('=')
    if entry.len == 2 and entry[0].strip() == "version":
      result = entry[1].strip(chars = {' ', '"'})
      break
  doAssert result.len > 0, "pymew.nimble has no version"

const pymewVersion* = parseVersion(staticRead("../pymew.nimble"))