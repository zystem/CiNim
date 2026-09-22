switch("mm", "orc")
switch("threads", "on")
switch("path", "$projectDir/../../src")
when defined(release):
  switch("opt", "size")
