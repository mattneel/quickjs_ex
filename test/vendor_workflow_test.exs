defmodule QuickjsEx.VendorWorkflowTest do
  use ExUnit.Case, async: false

  test "vendor workflow command validates checked-in QuickJS snapshots" do
    {sources, []} = Code.eval_file("vendor/quickjs_sources.exs")

    {output, status} =
      System.cmd("mix", ["quickjs.vendor.check"],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    Enum.each(sources, fn source ->
      assert output =~ source.label
      assert output =~ source.commit
    end)
  end
end
