defmodule WesexTest do
  alias Wesex.{Opening, Open, Closing, Closed}
  use ExUnit.Case
  doctest Wesex

  defmodule TestPlug do
    alias WesexTest.{OpenCallOk, ReceiveText, SendTextReceiveText}

    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/open_call_ok" do
      conn
      |> WebSockAdapter.upgrade(OpenCallOk, [], [])
      |> halt()
    end

    get "/open_call_error" do
      _ = conn
      exit(:normal)
    end

    get "/recv_text" do
      conn
      |> WebSockAdapter.upgrade(ReceiveText, [], [])
      |> halt()
    end

    get "/send_text_recv_text" do
      conn
      |> WebSockAdapter.upgrade(SendTextReceiveText, [], [])
    end

    get _ do
      dbg(conn.path)
      _ = conn
      exit(:normal)
    end
  end

  defmodule OpenCallOk do
    def init(_) do
      {:ok, []}
    end
  end

  defmodule SendTextReceiveText do
    def init(_) do
      {:ok, []}
    end

    def handle_in({"hello", opcode: :text}, s) do
      {:push, {:text, "world"}, s}
    end
  end

  defmodule ReceiveText do
    @behaviour WebSock
    def init(_) do
      {:push, {:text, "foo"}, nil}
    end

    def terminate(reason, state) do
      dbg({reason, state})
    end
  end

  defp port do
    System.get_env("WESEX_TEST_PORT", "5443") |> String.to_integer()
  end

  defp test_server do
    {
      Bandit,
      # max 100 bytes so we can test better
      plug: TestPlug,
      scheme: :http,
      port: port(),
      ip: :loopback,
      websocket_options: [max_frame_size: 100]
    }
  end

  defp url(path), do: "http://localhost:#{port()}#{path}"

  defmodule TestGenServer do
    import Wesex.Utils, only: [state_of_return: 1, nest_state_in_return: 3]
    use GenServer

    def start_link(report_to) do
      GenServer.start_link(__MODULE__, report_to)
    end

    @impl GenServer
    def init(report_to) do
      wesex_state = Wesex.init_state(nil)
      {:ok, %{Wesex => wesex_state, report_to: report_to}}
    end

    @impl GenServer
    def handle_call(request, from, state) do
      case Wesex.handle_call(request, from, state[Wesex]) do
        {result, return} ->
          send(state.report_to, {:handle_result, result})
          nest_state_in_return(return, state, Wesex)

        false ->
          send(state.report_to, {:unhandled, {:request, request}})
      end
    end

    @impl GenServer
    def handle_info(request, state) do
      case Wesex.handle_info(request, state[Wesex]) do
        {result, return} ->
          send(state.report_to, {:handle_result, result})
          nest_state_in_return(return, state, Wesex)

        false ->
          send(state.report_to, {:unhandled, {:info, request}})
      end
    end
  end

  setup_all do
    _test_server = start_link_supervised!(test_server())
    :ok
  end

  setup do
    %{client_gs: start_link_supervised!({TestGenServer, self()})}
  end

  # open call,
  # result :opening,
  # state Opening,
  # receive info,
  # result {:open, :ok},
  # call return ok
  test "open call, ok", %{client_gs: client_gs} do
    assert :ok = Wesex.call_open(client_gs, url("/open_call_ok"), [], 100)
    assert_received {:handle_result, :opening}
    assert_received {:handle_result, {:open, :ok}}
  end

  # open call,
  # result :opening,
  # state Opening,
  # receive info,
  # result {:open, {:error, reason}},
  # call return the same {:error, reason}
  test "open call, error", %{client_gs: client_gs} do
    assert {:error, reason} = Wesex.call_open(client_gs, url("/open_call_error"), [], 100)
    assert_receive {:handle_result, :opening}, 10
    assert_receive {:handle_result, {:open, {:error, ^reason}}}, 10
  end

  defp open(client_gs, path) do
    assert :ok = Wesex.call_open(client_gs, url(path), [], 100)
    assert_receive {:handle_result, :opening}, 10
    assert_receive {:handle_result, {:open, :ok}}, 10
    :ok
  end

  test "receive text", %{client_gs: client_gs} do
    path = "/recv_text"
    :ok = open(client_gs, path)

    assert_receive {:handle_result, {:receive, [{:text, "foo"}]}}, 100
  end

  test "send text, receive text", %{client_gs: client_gs} do
    path = "/send_text_recv_text"
    :ok = open(client_gs, path)

    assert :ok = Wesex.call_send(client_gs, {:text, "hello"})

    assert_receive {:handle_result, {:receive, [{:text, "world"}]}}, 100
  end
end
