return {
  {
    "jay-babu/mason-nvim-dap.nvim",
    lazy = false,
    opts = {
      ensure_installed = { "codelldb", "javadbg", "javatest", "js-debug-adapter" },
      automatic_installation = true,
    }
  },
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      "nvim-neotest/nvim-nio",
      "rcarriga/nvim-dap-ui"
    },
    config = function()
      local dap, dapui = require("dap"), require("dapui")

      dapui.setup()

      -- Auto open & close debug UI
      dap.listeners.before.attach.dapui_config = function() dapui.open() end
      dap.listeners.before.launch.dapui_config = function() dapui.open() end
      -- dap.listeners.before.event_terminated.dapui_config = function() dapui.close() end
      -- dap.listeners.before.event_exited.dapui_config = function() dapui.close() end

      -- zz при каждой остановке отладчика (step, breakpoint, etc.)
      dap.listeners.after.event_stopped.center_cursor = function()
        vim.schedule(function()
          if vim.bo.buftype ~= 'terminal' then
            vim.cmd('normal! zz')
          end
        end)
      end

      -- Auto open & close neotree
      local function close_neotree()
        vim.cmd("Neotree close")
      end

      local function open_neotree()
        vim.cmd("Neotree reveal")
        vim.cmd("wincmd l")
      end

      dap.listeners.before.attach.debug_neotree = function() close_neotree() end
      dap.listeners.before.launch.debug_neotree = function() close_neotree() end

      -- DAP adapters (shared across languages).
      dap.adapters.gdb = {
        type = "executable",
        command = "gdb",
        args = { "--interpreter=dap", "--eval-command", "set print pretty on" }
      }
      dap.adapters.codelldb = {
        type = "server",
        port = "${port}",
        executable = {
          command = "codelldb",
          args = {"--port", "${port}"},
        }
      }

      -- C/C++ DAP configurations are registered from lua/lang/cpp.lua.

      dap.configurations.rust = {
        {
          name = "Launch (codelldb)",
          type = "codelldb",
          request = "launch",
          program = function()
            local cwd = vim.fn.getcwd()
            local name = vim.fn.fnamemodify(cwd, ":t")
            local path = cwd .. "/target/debug/" .. name
            return path
          end,
          cwd = "${workspaceFolder}",
          stopOnEntry = false,
          -- args = function()
          --   local raw = vim.fn.input("Program arguments (space-separated): ")
          --   if raw == "" then return {} end
          --   return vim.split(raw, "%s+")
          -- end,
          -- runInTerminal = true,
          console = 'integratedTerminal',
        },
        -- {
        --   name = "Attach to process (pick)",
        --   type = "codelldb",
        --   request = "attach",
        --   pid = function()
        --      local name = vim.fn.input('Executable name (filter): ')
        --      return require("dap.utils").pick_process({ filter = name })
        --   end,
        -- },
      }

      -- dap.configurations.cpp / .c — see lua/lang/cpp.lua (setup_dap).
      -- dap.configurations.go — see lua/lang/go.lua (setup_dap): nvim-dap-go
      -- drives delve, re-configured per project so tag-gated tests are built.

      local uv = vim.loop

      local function find_java_exec()
        local java_home = os.getenv("JAVA_HOME")
        if java_home then
          return java_home .. "/bin/java"
        else
          -- fallback: try system java
          local handle = io.popen("which java")
          local result = handle:read("*a")
          handle:close()
          return result:gsub("%s+", "")
        end
      end

      local function get_project_name()
        return uv.fs_realpath(vim.fn.getcwd()):match("^.+/(.+)$")
      end

      -- JavaScript / TypeScript (Node.js)
      -- Адаптер "pwa-node" — это Node.js (не браузер).
      -- Браузер был бы "pwa-chrome", которого здесь нет.
      dap.adapters["pwa-node"] = {
        type = "server",
        host = "localhost",
        port = "${port}",
        executable = {
          command = "node",
          args = {
            vim.fn.stdpath("data") .. "/mason/packages/js-debug-adapter/js-debug/src/dapDebugServer.js",
            "${port}",
          },
        },
      }

      local js_config = {
        {
          name = "Launch (Node.js)",
          type = "pwa-node",
          request = "launch",
          program = "${file}",
          cwd = "${workspaceFolder}",
          console = "integratedTerminal",
          stopOnEntry = false,
        },
        {
          name = "Attach to process (Node.js)",
          type = "pwa-node",
          request = "attach",
          processId = function()
            return require("dap.utils").pick_process()
          end,
          cwd = "${workspaceFolder}",
        },
      }
      dap.configurations.javascript = js_config
      dap.configurations.typescript = js_config

      dap.configurations.java = {
        {
          classPaths = {},        -- nvim-jdtls добавит зависимости автоматически
          modulePaths = {},       -- для модульной системы
          projectName = get_project_name(),
          javaExec = find_java_exec(),
          mainClass = nil,        -- nvim-jdtls определит автоматически
          name = "Launch Java",
          request = "launch",
          type = "java",
        },
      }
      -- Debug keymaps
      vim.keymap.set('n', '<Leader>db', dap.toggle_breakpoint, {})
      vim.keymap.set('n', '<Leader>dr', dap.run_to_cursor, {})
      vim.keymap.set('n', '<Leader>dc', dap.continue, {})

      vim.keymap.set('n', '<Leader>di', dap.step_into, {})
      vim.keymap.set('n', '<Leader>do', dap.step_over, {})
      vim.keymap.set('n', '<Leader>dO', dap.step_out, {})
      vim.keymap.set('n', '<Leader>dl', dap.run_last, {})

      vim.keymap.set('n', '<A-l>', dap.step_into, {})
      vim.keymap.set('n', '<A-j>', dap.step_over, {})
      vim.keymap.set('n', '<A-h>', dap.step_out, {})
      vim.keymap.set('n', '<A-k>', dap.run_last, {})

      -- Stack frame navigation. codelldb does not advertise `supportsStepBack`,
      -- so `dap.step_back` is unavailable; walking up the frames is the closest
      -- way to inspect where the current call came from.
      vim.keymap.set('n', '<A-K>', dap.up, { desc = "Frame up" })
      vim.keymap.set('n', '<A-J>', dap.down, { desc = "Frame down" })

      -- One prompt chain: condition, hit count, log message. An empty answer
      -- leaves that field unset, so answering nothing three times yields a
      -- plain breakpoint. A non-empty log message makes it a logpoint: the
      -- session prints the message and keeps running instead of stopping.
      vim.keymap.set('n', '<Leader>dB', function()
        local function ask(prompt)
          local value = vim.fn.input({ prompt = prompt })
          return value ~= "" and value or nil
        end

        local condition = ask("Condition: ")
        local hit_condition = ask("Hit count: ")
        local log_message = ask("Log message: ")

        dap.set_breakpoint(condition, hit_condition, log_message)
      end, { desc = "Conditional breakpoint" })

      -- Evaluate the expression under the cursor, or the visual selection.
      vim.keymap.set({ 'n', 'v' }, '<Leader>de', function()
        dapui.eval(nil, { enter = true })
      end, { desc = "Evaluate expression" })

      vim.keymap.set('n', '<Leader>dt', function()
        dap.repl.toggle()
      end, { desc = "Toggle REPL" })

      vim.keymap.set('n', '<Leader>dR', dap.restart, { desc = "Restart session" })

      -- codelldb exposes Rust panics under the `rust_panic` filter. With it on,
      -- the session stops at the panic site instead of after the unwind, so the
      -- frame that caused it is still on the stack.
      local panic_breakpoint = false
      vim.keymap.set('n', '<Leader>dx', function()
        if not dap.session() then
          vim.notify("No active debug session", vim.log.levels.WARN)
          return
        end

        panic_breakpoint = not panic_breakpoint
        dap.set_exception_breakpoints(panic_breakpoint and { "rust_panic" } or {})
        vim.notify("Panic breakpoint: " .. (panic_breakpoint and "on" or "off"))
      end, { desc = "Toggle panic breakpoint" })

      vim.api.nvim_create_autocmd("BufEnter", {
        pattern = "[dap-terminal] Launch (codelldb)",
        callback = function()
          -- Go to insert mode automatically
          vim.cmd("startinsert")
        end,
      })

      vim.keymap.set('n', '<Leader>dw', function()
        require('dapui').elements.watches.add(vim.fn.expand('<cword>'))
      end)

      -- Hex value display. codelldb ignores the DAP `format.hex` option, so
      -- this goes through its own `_adapterSettings` request (session-wide) and
      -- through `,x` expression suffixes (per object). See utils/dap_hex.lua.
      local dap_hex = require("utils.dap_hex")
      dap_hex.setup()

      vim.keymap.set('n', '<Leader>dh', dap_hex.toggle_global, { desc = "Toggle hex for all values" })
      vim.keymap.set({ 'n', 'v' }, '<Leader>dH', dap_hex.toggle_under_cursor,
        { desc = "Toggle hex for the object under the cursor" })
      vim.keymap.set('n', '<Leader>dF', dap_hex.pick_format, { desc = "Pick value format" })

      vim.keymap.set('n', '<Leader>dq', function()
        require("dapui").close()
        require("dap").terminate()
      end, { desc = "Quit debugger" })

      dapui.setup()
    end,
  }
}
