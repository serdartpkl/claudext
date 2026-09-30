@{
    schemaVersion = 2

    # Every backup source and how it is handled.
    #   copy   - byte-for-byte copy
    #   remap  - the same as copy with Remap = $true (kept for older manifests)
    #   merge  - merge selected keys into the target file, never overwrite it
    #   skip   - never collected
    #   report - listed in INVENTORY.md, never restored
    #
    # Remap = $true rewrites old paths into new ones on restore when the home
    # directory changed — in text files only; anything else is copied byte for
    # byte.
    #
    # A Path is either a plain string (identical on every platform) or a
    # hashtable keyed by platform name. Only the Windows layout has been
    # verified against a real installation. Paths under ~/.claude follow the
    # Claude folder wherever it really is (CLAUDE_CONFIG_DIR, or one chosen).
    #
    # The archive is not encrypted, so no folder source ever takes a file
    # that holds a secret by its nature. Matched against every file name and
    # folder name, at any depth, in every folder source.
    SecretExclude = @('.credentials.json', '.env', '.env.*', '*.env', '.ssh', 'id_rsa', 'id_dsa',
                      'id_ecdsa', 'id_ed25519', '*.pem', '*.key', '*.pfx', '*.p12', '.netrc', '.npmrc',
                      '.pypirc')

    Sources = @(
        # Sessions, and each project's auto memory in its memory/ folder.
        # The claude-mem plugin runs its own Claude sessions from a working
        # directory under ~/.claude-mem, so those transcripts land here as a
        # project folder named '<home>--claude-mem-...'. They are the plugin
        # talking to itself, not your work, and they were 405 MB. Only that
        # folder name is matched: a project of yours called claude-memory-x,
        # or a memory file named after it, is kept.
        @{ Id = 'transcripts'; Label = 'Transcripts & Memory'; Type = 'copy'; Remap = $true
           Path = '~/.claude/projects'; ExcludeTop = @('*--claude-mem', '*--claude-mem-*') }

        @{ Id = 'skills';   Label = 'Skills';         Type = 'copy'; Remap = $true; Path = '~/.claude/skills' }
        @{ Id = 'tasks';    Label = 'Tasks';          Type = 'copy'; Remap = $true; Path = '~/.claude/tasks' }
        # Every prompt typed, filed by project path: up-arrow recall looks a
        # project's history up by that path, so it is rewritten with the rest.
        @{ Id = 'history';  Label = 'Prompt History'; Type = 'copy'; Remap = $true; Path = '~/.claude/history.jsonl' }
        @{ Id = 'settings'; Label = 'Settings';       Type = 'copy'; Remap = $true; Path = '~/.claude/settings.json' }

        # Everything else in the Claude folder: CLAUDE.md, rules/, agents/,
        # commands/, output-styles/, themes/, workflows/, agent-memory/,
        # keybindings.json, plans/, the paste cache that recalled prompts
        # point into, Remote Control uploads that transcripts refer to, the
        # /usage totals — and whatever a later Claude Code adds. The other
        # sources' own paths are left out automatically; ExcludeTop lists
        # what is cache, live state, a secret or this machine's identity.
        @{ Id = 'other'; Label = 'Everything Else'; Type = 'copy'; Remap = $true
           Path = '~/.claude'; CatchAll = $true
           ExcludeTop = @('.credentials.json', '.claude.json', 'plugins', 'sessions', 'session-env',
                          'shell-snapshots', 'debug', 'telemetry', 'statsig', 'cache', 'downloads',
                          'ide', 'file-history', 'image-cache', 'feedback', 'local', 'logs',
                          'remote-settings.json', 'policy-limits.json', '.last-cleanup',
                          'claudext-replaced', '*.lock', '*.tmp') }

        # Mixes portable state with machine identity. Only the portable keys
        # go into the archive — the account, the user id and any API key stay
        # behind — and they are merged key by key, never over the whole file.
        # The last five are /config choices kept here, not in settings.json.
        @{ Id = 'claude-json'; Label = 'Project Records'; Type = 'merge'; Remap = $true
           Path = '~/.claude.json'
           PortableKeys = @('projects', 'skillUsage', 'pluginUsage', 'toolUsage',
                            'githubRepoPaths', 'tipsHistory', 'mcpServers',
                            'autoConnectIde', 'autoInstallIdeExtension', 'copyOnSelect',
                            'diffTool', 'externalEditorContext') }

        # Same treatment: mcpServers and preferences are portable, the
        # account-scoped keys are not. The desktop app stores its config in a
        # different place on each OS; only the Windows path is verified
        # against a real install.
        @{ Id = 'desktop-config'; Label = 'Desktop App Config'; Type = 'merge'; Remap = $true
           Path = @{
               Windows = '~/AppData/Roaming/Claude/claude_desktop_config.json'
               macOS   = '~/Library/Application Support/Claude/claude_desktop_config.json'
               Linux   = '~/.config/Claude/claude_desktop_config.json'
           }
           PortableKeys = @('mcpServers', 'preferences') }

        # OAuth token and trusted-device token. The archive is unencrypted and
        # a fresh /login costs ten seconds.
        @{ Id = 'credentials'; Type = 'skip'; Path = '~/.claude/.credentials.json' }

        # Claude Code's own timed copies of ~/.claude.json, whole: account,
        # user id and any API key included. They serve to recover that file on
        # the machine that wrote them, and the new machine starts its own.
        # Archives from before this carry them; they are not restored.
        @{ Id = 'backups'; Label = 'Config Backups'; Type = 'skip'; Path = '~/.claude/backups' }

        # Reinstalled by Claude Code; INVENTORY.md lists every enabled plugin
        # with its marketplace, in case one has to be added back by hand.
        @{ Id = 'plugins';     Type = 'skip'; Path = '~/.claude/plugins' }

        # Live session state, meaningless after a reboot.
        @{ Id = 'sessions';        Type = 'skip'; Path = '~/.claude/sessions' }
        @{ Id = 'session-env';     Type = 'skip'; Path = '~/.claude/session-env' }
        @{ Id = 'shell-snapshots'; Type = 'skip'; Path = '~/.claude/shell-snapshots' }
        @{ Id = 'file-history';    Type = 'skip'; Path = '~/.claude/file-history' }
        @{ Id = 'debug';           Type = 'skip'; Path = '~/.claude/debug' }
        @{ Id = 'telemetry';       Type = 'skip'; Path = '~/.claude/telemetry' }
        @{ Id = 'cache';           Type = 'skip'; Path = '~/.claude/cache' }
        @{ Id = 'downloads';       Type = 'skip'; Path = '~/.claude/downloads' }

        @{ Id = 'installed-software'; Type = 'report'; Path = '' }
    )
}
