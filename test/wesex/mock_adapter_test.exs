defmodule MockAdapterTest do
  use ExUnit.Case, async: true
  alias Wesex.MockServer
  alias Wesex.MockAdapter

  @moduletag timeout: 5_000

  defmodule MockWebsock do
    @behaviour WebSock
    @impl true
    def init(_) do
      {:ok, []}
    end

    @impl true
    def handle_in({data, opcode: type}, state) do
      {:ok, [{type, data} | state]}
    end

    @impl true
    def handle_info(term, _state) do
      raise "unexpected message, #{inspect(term)}"
    end
  end

  @mock_uri URI.new!("wss://mock/foo?a=1")

  setup do
    mock_server =
      start_supervised!({MockServer, websock: MockWebsock, uri: @mock_uri, send_to: self()},
        id: :closed_mock_server
      )

    connected_server =
      start_supervised!({MockServer, websock: MockWebsock, uri: @mock_uri, send_to: self()},
        id: :connected_mock_server
      )

    {:ok, ^connected_server} = MockAdapter.connect(@mock_uri, [], server: connected_server)

    %{mock_server: mock_server, connected: connected_server}
  end

  describe "connect/3" do
    test "returns ok", %{mock_server: server} do
      assert {:ok, _adapter} = MockAdapter.connect(@mock_uri, [], server: server)
    end

    test "returns error at wrong uri", %{mock_server: server} do
      assert {:error, _adapter} =
               MockAdapter.connect(URI.new!("wss://mock/bar"), [], server: server)
    end
  end

  describe "event/2" do
    test "returns false for unhandled raw events", %{mock_server: server} do
      assert MockAdapter.event(server, :unhandled_event) == false
    end

    test "{:mock_server_messages, _}", %{mock_server: server} do
      messages = [text: "abc", ping: nil]
      {^server, events} = MockAdapter.event(server, {:mock_server_messages, messages})
      assert events == messages
    end

    test ":tcp_close at monitored down message", %{connected: server} do
      :ok = GenServer.stop(server, {:shutdown, :stop})

      assert_receive {:DOWN, _ref, :process, ^server, _reason} = msg, 10

      {^server, events} = MockAdapter.event(server, msg)
      assert events == [:tcp_close]
    end
  end

  defp receive_events(state, timeout \\ 5) do
    receive do
      msg ->
        case MockAdapter.event(state, msg) do
          {_state, events} ->
            receive_events(state, timeout) ++ events
            # false -> []
        end
    after
      timeout -> []
    end
  end

  describe "server behavior" do
    test "send_pong/2", %{connected: server} do
      {^server, events} = MockAdapter.send_pong(server, nil)
      events = events ++ receive_events(server)
      assert events == []
      # handle_control not implemented
      # assert [:pong] == MockServer.dump_state(server)
    end

    test "send ping, get pong", %{connected: server} do
      {^server, events} = MockAdapter.send_ping(server)
      events = events ++ receive_events(server)
      assert events == [pong: nil]
    end

    test "client close", %{connected: server} do
      code_reason = {1000, "foo"}
      {^server, events} = MockAdapter.local_close(server, code_reason)
      events = events ++ receive_events(server)
      assert events == [{:close, 1000, nil}, :tcp_close]
    end

    test "abort", %{connected: server} do
      {^server, events} = MockAdapter.abort(server)

      events = events ++ receive_events(server)
      assert events == [:tcp_close]
    end

    test "send", %{connected: server} do
      message = {:text, "Hello"}
      assert {:ok, server, []} == MockAdapter.send(server, message)
      assert [text: "Hello"] == MockServer.dump_state(server)
    end

    test "send when no server", %{connected: server} do
      :ok = GenServer.stop(server, {:shutdown, :stop})
      message = {:text, "Hello"}
      assert {:error, _state, _events, _reason} = MockAdapter.send(server, message)
    end
  end
end
