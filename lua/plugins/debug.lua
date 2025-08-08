return { "mfussenegger/nvim-dap",
  dependencies = {
    'nvim-neotest/nvim-nio',
    "rcarriga/nvim-dap-ui"
  },
  config = function()
    local dap, dapui = require("dap"), require("dapui")

    dapui.setup()

    -- Auto open & close debug UI
    dap.listeners.before.attach.dapui_config = function()
      dapui.open()
    end
    dap.listeners.before.launch.dapui_config = function()
      dapui.open()
    end
    dap.listeners.before.event_terminated.dapui_config = function()
      dapui.close()
    end
    dap.listeners.before.event_exited.dapui_config = function()
      dapui.close()
    end

    -- Configure DAP for C/C++/Rust
    dap.adapters.gdb = {
      type = "executable",
      command = "gdb",
      args = { "--interpreter=dap", "--eval-command", "set print pretty on" }
    }

    dap.configurations.c = {
      {
        name = "Launch",
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
    dap.configurations.rust = dap.configurations.c

    -- Debug keymaps
    vim.keymap.set('n', '<Leader>db', dap.toggle_breakpoint, {})
    vim.keymap.set('n', '<Leader>dr', dap.run_to_cursor, {})
    vim.keymap.set('n', '<Leader>dc', dap.continue, {})

    vim.keymap.set('n', '<Leader>di', dap.step_into, {})
    vim.keymap.set('n', '<Leader>do', dap.step_over, {})
    vim.keymap.set('n', '<Leader>dO', dap.step_out, {})
    vim.keymap.set('n', '<Leader>dl', dap.run_last, {})

    vim.keymap.set('n', '<Leader>dq', function()
      require("dapui").close()
      require("dap").terminate()
    end, { desc = "Quit debugger" })

    dapui.setup()
  end,
}
