return {
  {
    "jay-babu/mason-nvim-dap.nvim",
    lazy = false,
    opts = {
      ensure_installed = { "codelldb" },
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

      -- Configure DAP for C/C++
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

      dap.configurations.c = {
        {
          name = "Launch (gdb)",
          type = "gdb",
          request = "launch",
          program = function()
            return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/', 'file')
          end,
          cwd = "${workspaceFolder}",
          stopAtBeginningOfMainSubprogram = false,
        },
        {
          name = "Select and attach to process",
          type = "gdb",
          request = "attach",
          program = function()
             return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/', 'file')
          end,
          pid = function()
             local name = vim.fn.input('Executable name (filter): ')
             return require("dap.utils").pick_process({ filter = name })
          end,
          cwd = '${workspaceFolder}'
        },
        {
          name = 'Attach to gdbserver :1234',
          type = 'gdb',
          request = 'attach',
          target = 'localhost:1234',
          program = function()
             return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/', 'file')
          end,
          cwd = '${workspaceFolder}'
        },
      }
      dap.configurations.cpp = dap.configurations.c

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

      -- Debug keymaps
      vim.keymap.set('n', '<Leader>db', dap.toggle_breakpoint, {})
      vim.keymap.set('n', '<Leader>dr', dap.run_to_cursor, {})
      vim.keymap.set('n', '<Leader>dc', dap.continue, {})

      vim.keymap.set('n', '<Leader>di', dap.step_into, {})
      vim.keymap.set('n', '<Leader>do', dap.step_over, {})
      vim.keymap.set('n', '<Leader>dO', dap.step_out, {})
      vim.keymap.set('n', '<Leader>dl', dap.run_last, {})
      vim.keymap.set('n', '<Leader>dw', function()
        require('dapui').elements.watches.add(vim.fn.expand('<cword>'))
      end)

      vim.keymap.set('n', '<Leader>dq', function()
        require("dapui").close()
        require("dap").terminate()
        open_neotree()
      end, { desc = "Quit debugger" })

      vim.keymap.set('n', 'l', function()
        local element = require("dapui.components").get_element_under_cursor()
        if element then
          require("dapui.components").expand(element)
        end
      end, { buffer = true })

      vim.keymap.set('n', 'h', function()
        local element = require("dapui.components").get_element_under_cursor()
        if element then
          require("dapui.components").collapse(element)
        end
      end, { buffer = true })

      dapui.setup()
    end,
  }
}
