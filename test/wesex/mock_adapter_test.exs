defmodule MockAdapterTest do
  use ExUnit.Case, async: true
  alias Wesex.MockServer
  alias Wesex.MockAdapter

  @moduletag timeout: 5_000

  defmodule MockWebsock do
    @behaviour WebSock
    @impl true
    def init({_, _, _}) do
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
      start_supervised!({MockServer, websock: MockWebsock, uri: @mock_uri, send_to: self()})

    {:ok, adapter_state} = MockAdapter.connect(@mock_uri, [], server: mock_server)
    connected_conn_holder = MockAdapter.get_conn_holder(adapter_state)

    %{
      mock_server: mock_server,
      connected: adapter_state,
      connected_conn_holder: connected_conn_holder
    }
  end

  describe "connect/3" do
    setup ctx do
      [:handshake_complete] = receive_events(ctx.connected)
      :ok
    end

    test "returns ok", %{mock_server: server} do
      assert {:ok, _adapter} = MockAdapter.connect(@mock_uri, [], server: server)
    end

    test "returns ok, receive events, is connected", %{mock_server: server} do
      assert {:ok, state} = MockAdapter.connect(@mock_uri, [], server: server)
      adapter_events = receive_events(state)
      assert [:handshake_complete] == adapter_events
    end
  end

  describe "event/2" do
    test "returns false for unhandled raw events", %{connected: state} do
      assert MockAdapter.event(:unhandled_event, state) == false
    end

    test "{:mock_server_messages, _}", %{connected: state} do
      messages = [text: "abc", ping: nil]
      {events, ^state} = MockAdapter.event({state.ref, {:mock_server_messages, messages}}, state)
      assert events == messages
    end

    test ":tcp_close at monitored down message", %{
      connected: state,
      connected_conn_holder: conn_holder
    } do
      :ok = GenServer.stop(conn_holder, {:shutdown, :stop})

      assert_receive {:DOWN, _ref, :process, ^conn_holder, _reason} = msg, 10

      {events, ^state} = MockAdapter.event(msg, state)
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

    test "send_pong/2", %{connected: state} do
      {events, ^state} = MockAdapter.send_pong(nil, state)
      events = events ++ receive_events(state)
      assert events == []
      # handle_control not implemented
      # assert [:pong] == MockServer.dump_state(server)
    end

    test "send ping, get pong", %{connected: state} do
      {events, ^state} = MockAdapter.send_ping(state)
      events = events ++ receive_events(state)
      assert events == [pong: nil]
    end

    test "client close", %{connected: state} do
      code_reason = {1000, "foo"}
      {events, ^state} = MockAdapter.local_close(code_reason, state)
      events = events ++ receive_events(state)
      assert events == [{:close, 1000, nil}, :tcp_close]
    end

    test "abort", %{connected: state} do
      {events, ^state} = MockAdapter.abort(state)

      events = events ++ receive_events(state)
      assert events == [:tcp_close]
    end

    test "send", %{connected: state, connected_conn_holder: conn_holder} do
      message = {:text, "Hello"}
      assert {:ok, [], state} == MockAdapter.send(message, state)
      assert [text: "Hello"] == Wesex.MockServer.ConnectionHolder.dump_state(conn_holder)
    end

    test "send when no server", %{connected: state, connected_conn_holder: conn_holder} do
      :ok = GenServer.stop(conn_holder, {:shutdown, :stop})
      message = {:text, "Hello"}
      assert {:error, _state, _events, _reason} = MockAdapter.send(message, state)
    end
  end
end
