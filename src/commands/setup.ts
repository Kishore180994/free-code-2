import type { Command } from '../commands.js'

const setup: Command = {
  type: 'local',
  name: 'setup',
  description: 'Run the interactive setup wizard to configure your AI provider',
  isEnabled: true,
  isHidden: false,
  async call() {
    const { execSync } = await import('child_process')
    const path = await import('path')
    const { fileURLToPath } = await import('url')

    // Resolve the setup wizard script path relative to the binary
    const currentDir = path.dirname(fileURLToPath(import.meta.url))
    const scriptPath = path.resolve(currentDir, '../../scripts/setup-wizard.sh')

    try {
      execSync(`bash "${scriptPath}"`, { stdio: 'inherit' })
    } catch (e: unknown) {
      // Check if script doesn't exist at the resolved path, try alternative locations
      const altPaths = [
        path.resolve(process.cwd(), 'scripts/setup-wizard.sh'),
        path.resolve(process.env.HOME ?? '~', 'free-code/scripts/setup-wizard.sh'),
      ]
      let found = false
      for (const alt of altPaths) {
        try {
          const { existsSync } = await import('fs')
          if (existsSync(alt)) {
            execSync(`bash "${alt}"`, { stdio: 'inherit' })
            found = true
            break
          }
        } catch { /* continue */ }
      }
      if (!found) {
        console.error('Setup wizard not found. Run it manually: bash ./scripts/setup-wizard.sh')
      }
    }

    return { type: 'empty' as const }
  },
  userFacingName() {
    return 'setup'
  },
}

export default setup
