-- .pl, .pro, .plt → prolog (override Perl, который ловит .pl по умолчанию).
-- Если когда-то понадобится Perl-файл с .pl — :set ft=perl вручную.
vim.filetype.add({
  extension = {
    pl  = "prolog",
    pro = "prolog",
    plt = "prolog",
  },
})
