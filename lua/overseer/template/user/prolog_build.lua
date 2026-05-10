-- Run / Build для Prolog.
--   * если в cwd лежит RunProlog.sh (как в курсе ITMO paradigms-2026) — запускаем его
--   * иначе — java -jar 2p-*.jar (откроет GUI tuProlog IDE как fallback)
return {
  name = "tuProlog Run",
  builder = function()
    local cwd = vim.fn.getcwd()
    if vim.fn.filereadable(cwd .. "/RunProlog.sh") == 1 then
      return {
        cmd = { "bash" },
        args = { "RunProlog.sh" },
        cwd = cwd,
        components = { { "on_output_quickfix", open = false }, "default" },
      }
    end
    local jar = require("prolog.repl").find_jar()
    if not jar then
      vim.notify("tuProlog jar не найден (vim.g.tuprolog_jar или ./lib/2p-*.jar)", vim.log.levels.ERROR)
      return nil
    end
    return {
      cmd = { "java" },
      args = { "-Dfile.encoding=UTF-8", "-jar", jar },
      cwd = cwd,
      components = { { "on_output_quickfix", open = false }, "default" },
    }
  end,
  condition = {
    filetype = { "prolog" },
  },
}
