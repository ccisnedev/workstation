import { describe, expect, mock, test } from 'claude-code/testing'

// The address the workstation gives a window's Neovim, as the mod reads it
// from the agent pane's environment.
const ADDRESS = '\\\\.\\pipe\\workstation-nvim-test'

// What the mod runs, once per edited file. The Neovim side is exercised for
// real by Invoke-EditorQA, which runs this same argv against a headless
// Neovim; here the world beneath the mod is stubbed.
function reloadArgv(path: string): string[] {
  return ['nvim', '--headless', '--server', ADDRESS, '--remote-expr', `v:lua.workstation_reload('${path.replaceAll("'", "''")}')`]
}

// Records every process the mod starts, and answers each with `answer`.
function recordProcesses(on: any, answer: () => unknown = () => ({ value: { exitCode: 0, stdout: '', stderr: '' } })) {
  const runs: { argv: readonly string[]; init?: any }[] = []
  on('process.run', ($: any, e: any) => {
    runs.push({ argv: e.argv, init: e.init })
    return answer()
  })
  return runs
}

describe('reload', () => {
  test('after an Edit the mod tells Neovim the absolute path, by a fixed argv', async ($, on) => {
    mock.env(on, { WORKSTATION_NVIM_SERVER: ADDRESS })
    on('tool.call', () => ({ result: 'ok' }))
    const runs = recordProcesses(on)

    await $.tool.call({ tool: 'Edit', file_path: 'C:/work/a.txt', old_string: 'a', new_string: 'b' })

    expect(runs.map((r) => r.argv)).toEqual([reloadArgv('C:/work/a.txt')])
  })

  test('Write and NotebookEdit tell Neovim too, each by its own path field', async ($, on) => {
    mock.env(on, { WORKSTATION_NVIM_SERVER: ADDRESS })
    on('tool.call', () => ({ result: 'ok' }))
    const runs = recordProcesses(on)

    await $.tool.call({ tool: 'Write', file_path: 'C:/work/b.txt', content: 'x' })
    await $.tool.call({ tool: 'NotebookEdit', notebook_path: 'C:/work/n.ipynb', new_source: 'x' })

    expect(runs.map((r) => r.argv)).toEqual([reloadArgv('C:/work/b.txt'), reloadArgv('C:/work/n.ipynb')])
  })

  test('a path with a quote reaches Neovim as one string', async ($, on) => {
    mock.env(on, { WORKSTATION_NVIM_SERVER: ADDRESS })
    on('tool.call', () => ({ result: 'ok' }))
    const runs = recordProcesses(on)

    await $.tool.call({ tool: 'Write', file_path: "C:/work/it's.txt", content: 'x' })

    expect(runs[0].argv[5]).toBe("v:lua.workstation_reload('C:/work/it''s.txt')")
  })

  test('other tools trigger nothing', async ($, on) => {
    mock.env(on, { WORKSTATION_NVIM_SERVER: ADDRESS })
    on('tool.call', () => ({ result: 'ok' }))
    const runs = recordProcesses(on)

    await $.tool.call({ tool: 'Read', file_path: 'C:/work/a.txt' })
    await $.tool.call({ tool: 'Bash', command: 'ls' })

    expect(runs).toEqual([])
  })

  test('with the variable unset nothing runs for any tool', async ($, on) => {
    mock.env(on, {})
    on('tool.call', () => ({ result: 'ok' }))
    const runs = recordProcesses(on)

    await $.tool.call({ tool: 'Edit', file_path: 'C:/work/a.txt', old_string: 'a', new_string: 'b' })
    await $.tool.call({ tool: 'Write', file_path: 'C:/work/a.txt', content: 'x' })

    expect(runs).toEqual([])
  })

  test('a process that cannot start leaves the result as the engine returned it', async ($, on) => {
    mock.env(on, { WORKSTATION_NVIM_SERVER: ADDRESS })
    on('tool.call', () => ({ result: 'engine answer' }))
    recordProcesses(on, () => ({ deny: 'nvim is not installed' }))

    const answer = await $.tool.call({ tool: 'Edit', file_path: 'C:/work/a.txt', old_string: 'a', new_string: 'b' })

    expect(answer.result).toBe('engine answer')
  })

  test('a non-zero exit leaves the result as the engine returned it', async ($, on) => {
    mock.env(on, { WORKSTATION_NVIM_SERVER: ADDRESS })
    on('tool.call', () => ({ result: 'engine answer' }))
    recordProcesses(on, () => ({ value: { exitCode: 1, stdout: '', stderr: 'E247: no registered server' } }))

    const answer = await $.tool.call({ tool: 'Edit', file_path: 'C:/work/a.txt', old_string: 'a', new_string: 'b' })

    expect(answer.result).toBe('engine answer')
  })

  test('an edit the tool refused reloads nothing', async ($, on) => {
    mock.env(on, { WORKSTATION_NVIM_SERVER: ADDRESS })
    on('tool.call', () => ({ deny: 'refused' }))
    const runs = recordProcesses(on)

    await $.tool.call({ tool: 'Edit', file_path: 'C:/work/a.txt', old_string: 'a', new_string: 'b' })

    expect(runs).toEqual([])
  })
})
