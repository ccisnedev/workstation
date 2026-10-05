// Tells the workstation's Neovim which file the agent just edited, so it can
// reload the buffer. See docs/adr/0009-the-editor-reloads-what-the-agent-edited.md
//
// The mod only reports. It never denies, delays or alters a tool call, and
// whatever goes wrong here, the edit proceeds exactly as without the mod.
//
// What it may call, and nothing else: $.env.get for the Neovim address and
// $.process.run for one fixed argv.

// The tools that write a file, and the field of each that names it.
const PATH_FIELDS = {
  Edit: 'file_path',
  Write: 'file_path',
  MultiEdit: 'file_path',
  NotebookEdit: 'notebook_path',
}

// A Vim single-quoted string: the only escape is a doubled quote.
function vimString(text) {
  return "'" + text.replaceAll("'", "''") + "'"
}

export function register(on) {
  on('tool.call', async ($, e, next) => {
    const result = await next(e)

    const field = PATH_FIELDS[e.tool]
    if (field === undefined) return result
    if (result.deny !== undefined || result.isError === true) return result

    try {
      const address = await $.env.get('WORKSTATION_NVIM_SERVER')
      const path = e[field]
      if (!address || typeof path !== 'string') return result

      await $.process.run([
        'nvim', '--headless',
        '--server', address,
        '--remote-expr', 'v:lua.workstation_reload(' + vimString(path) + ')',
      ])
    } catch {
      // Neovim is closed, absent or unreachable: nothing to tell, nothing to fix.
    }
    return result
  })
}
