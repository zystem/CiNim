## Writes docs/state-machines.md from the state tables: nim r tools/gen_state_docs.nim
import common/states
writeFile("docs/state-machines.md", renderDocs())
