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
    setup ctx do
      [:handshake_complete] = receive_events(ctx.connected)
      :ok
    end

    test "returns ok", %{mock_server: server} do
      assert {:ok, _adapter} = MockAdapter.connect(@mock_uri, [], server: server)
    end

    test "returns error at wrong uri", %{mock_server: server} do
      assert {:error, _adapter} =
               MockAdapter.connect(URI.new!("wss://mock/bar"), [], server: server)
    end

    test "returns ok, receive events, is connected", %{mock_server: server} do
      assert {:ok, state} = MockAdapter.connect(@mock_uri, [], server: server)
      adapter_events = receive_events(state)
      assert [:handshake_complete] == adapter_events
    end
  end

  describe "event/2" do
    test "returns false for unhandled raw events", %{mock_server: server} do
      assert MockAdapter.event(server, :unhandled_event) == false
    end

    test "{:mock_server_messages, _}", %{mock_server: server} do
      messages = [text: "abc", ping: nil]
      {events, ^server} = MockAdapter.event({:mock_server_messages, messages}, server)
      assert events == messages
    end

    test ":tcp_close at monitored down message", %{connected: server} do
      :ok = GenServer.stop(server, {:shutdown, :stop})

      assert_receive {:DOWN, _ref, :process, ^server, _reason} = msg, 10

      {events, ^server} = MockAdapter.event(msg, server)
      assert events == [:tcp_close]
    end
  end

  defp receive_events(state, timeout \\ 5) do
    receive do
      msg ->
        case MockAdapter.event(msg, state) do
          {events, ^state} ->
            receive_events(state, timeout) ++ events
            # false -> []
        end
    after
      timeout -> []
    end
  end

  describe "server behavior" do
    setup ctx do
      [:handshake_complete] = receive_events(ctx.connected)
      :ok
    end

    test "send_pong/2", %{connected: server} do
      {events, ^server} = MockAdapter.send_pong(nil, server)
      events = events ++ receive_events(server)
      assert events == []
      # handle_control not implemented
      # assert [:pong] == MockServer.dump_state(server)
    end

    test "send ping, get pong", %{connected: server} do
      {events, ^server} = MockAdapter.send_ping(server)
      events = events ++ receive_events(server)
      assert events == [pong: nil]
    end

    test "client close", %{connected: server} do
      code_reason = {1000, "foo"}
      {events, ^server} = MockAdapter.local_close(code_reason, server)
      events = events ++ receive_events(server)
      assert events == [{:close, 1000, nil}, :tcp_close]
    end

    test "abort", %{connected: server} do
      {events, ^server} = MockAdapter.abort(server)

      events = events ++ receive_events(server)
      assert events == [:tcp_close]
    end

    test "send", %{connected: server} do
      message = {:text, "Hello"}
      assert {:ok, [], server} == MockAdapter.send(message, server)
      assert [text: "Hello"] == MockServer.dump_state(server)
    end

    test "send when no server", %{connected: server} do
      :ok = GenServer.stop(server, {:shutdown, :stop})
      message = {:text, "Hello"}
      assert {:error, _state, _events, _reason} = MockAdapter.send(message, server)
    end
  end
end
