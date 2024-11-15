defmodule AutobahnTest do
  alias Wesex.Connection
  use Wesex
  @behaviour Connection

  # Fails 6.4.3 and 6.4.4 when we send a ping first
  # Maybe a mint_web_socket bug?

  def start_link(opts) do
    {wesex_opts, genserver_opts} = Keyword.split(opts, [:url, :headers, :adapter_opts, :init_arg])
    GenServer.start_link(__MODULE__, wesex_opts, genserver_opts)
  end

  @impl GenServer
  def init(init_arg) do
    super([{:callbacks, __MODULE__}, {:cb_state, nil} | init_arg])
  end

  @impl Connection
  def handle_connected(state) do
    {:ok, state, []}
  end

  @impl Connection
  def handle_in({type, data}, state, _status) do
    {:ok, state, [{type, data, make_ref()}]}
  end

  def run(from, to) do
    Task.async_stream(
      from..to,
      fn i ->
        {_pid, ref} =
          spawn_monitor(fn -> run_case(i) end)

        receive do
          {:DOWN, ^ref, _, _, _} ->
            nil
        end
      end,
      timeout: 300_000,
      max_concurrency: 20
    )
    |> Stream.run()
  end

  defp run_case(i) do
    {:ok, ws} =
      start_link(url: "ws://127.0.0.1:9001/runCase?case=#{i}&agent=wesex")

    ref = Process.monitor(ws)

    receive do
      {:DOWN, ^ref, _, _, _} -> nil
    end
  end

  def update_report do
    {:ok, _ws} =
      start_link(url: "ws://127.0.0.1:9001/updateReports?agent=wesex")
  end
end

"""
podman run -it --rm \
    -v "${PWD}/autobahn/config:/config" \
    -v "${PWD}/autobahn/reports:/reports" \
    -p 9001:9001 \
    --name fuzzingserver \
    crossbario/autobahn-testsuite
"""
