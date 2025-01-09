# Modified from the library "bandit",
# commit: 6f5caccedc13ba38e56ceaf88b482539f89b2f25,
# files: test/bandit/websocket/sock_test.exs and test/support/noop_sock.ex
# Original licensed under the MIT license, (c) 2020 Mat Trudel

defmodule MockServerWebSockTest do
  alias Wesex.MockAdapter
  alias Wesex.MockServer
  use ExUnit.Case, async: true

  defmodule NoopWebSock do
    @moduledoc false

    defmacro __using__(_) do
      quote do
        @behaviour WebSock

        @impl true
        def init(arg), do: {:ok, arg}

        @impl true
        def handle_in(_data, state), do: {:ok, state}

        @impl true
        def handle_info(_msg, state), do: {:ok, state}

        @impl true
        def terminate(_reason, _state), do: :ok

        defoverridable init: 1, handle_in: 2, handle_info: 2, terminate: 2
      end
    end
  end

  @mock_uri URI.new!("wss://mock/foo?a=1")

  defp receive_events(server, timeout \\ 5) do
    receive do
      msg ->
        case MockAdapter.event(msg, server) do
          {events, ^server} ->
            events ++ receive_events(server, timeout)
            # false -> []
        end
    after
      timeout -> []
    end
  end

  defp start_mock_server(websock) do
    start_supervised!({MockServer, websock: websock, uri: @mock_uri, send_to: self()})
  end

  describe "init" do
    defmodule InitOKStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return an ok tuple and update state" do
      server = start_mock_server(InitOKStateWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = receive_events(server) ++ events

      assert events == [:handshake_complete, {:text, inspect(:init)}]
    end

    defmodule InitPushStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, {:text, "init push"}, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return a push tuple and update state" do
      server = start_mock_server(InitPushStateWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events0 = receive_events(server)
      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = events0 ++ events1 ++ receive_events(server)

      init = inspect(:init)
      assert [:handshake_complete, {:text, "init push"}, {:text, ^init}] = events
    end

    defmodule InitReplyStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:reply, :ok, {:text, "init"}, :init}
      def handle_in(_data, state), do: {:push, {:text, inspect(state)}, state}
    end

    test "can return a reply tuple and update state" do
      server = start_mock_server(InitReplyStateWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events0 = receive_events(server)
      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = events0 ++ events1 ++ receive_events(server)

      init = inspect(:init)
      assert [_, _, {:text, ^init}] = events
    end

    defmodule InitTextWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, {:text, "TEXT"}, :init}
    end

    test "can return a text frame" do
      server = start_mock_server(InitTextWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [:handshake_complete, {:text, "TEXT"}] == events
    end

    defmodule InitBinaryWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, {:binary, "BINARY"}, :init}
    end

    test "can return a binary frame" do
      server = start_mock_server(InitBinaryWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [:handshake_complete, {:binary, "BINARY"}] == events
    end

    # def init(_opts), do: {:push, {:ping, "PING"}, :init}
    # test "can return a ping frame"

    # def init(_opts), do: {:push, {:pong, "PONG"}, :init}
    # test "can return a pong frame"

    defmodule InitListWebSock do
      use NoopWebSock
      def init(_opts), do: {:push, [{:binary, "BINARY"}, {:text, "TEXT"}], :init}
    end

    test "can return a list of frames" do
      server = start_mock_server(InitListWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [:handshake_complete, {:binary, "BINARY"}, {:text, "TEXT"}] == events
    end

    defmodule InitCloseWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :normal, :init}
    end

    test "can close a connection by returning a stop tuple" do
      server = start_mock_server(InitCloseWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [{:close, 1000, nil}] = events
    end

    # def init(_opts), do: {:stop, :abnormal, :init}
    # test "can close a connection with an error by returning an abnormal stop tuple"

    defmodule InitCloseWithCodeWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :normal, 5555, :init}
    end

    test "can close a connection by returning a stop tuple with a code" do
      server = start_mock_server(InitCloseWithCodeWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [{:close, 5555, nil}] == events
    end

    defmodule InitCloseWithCodeAndMessagesWebSock do
      use NoopWebSock

      def init(_opts), do: {:stop, :normal, 5555, [{:text, "first"}, {:text, "second"}], :init}
    end

    test "can close a connection by returning a stop tuple with a code and messages" do
      server = start_mock_server(InitCloseWithCodeAndMessagesWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [{:text, "first"}, {:text, "second"}, {:close, 5555, nil}] == events
    end

    defmodule InitCloseWithRestartWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, {:shutdown, :restart}, :init}
    end

    @tag skip: true
    test "can close a connection by returning an {:shutdown, :restart} tuple" do
      server = start_mock_server(InitCloseWithRestartWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = events ++ receive_events(server)

      assert [{:close, 1012, nil}] == events
    end

    defmodule InitCloseWithCodeAndNilDetailWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :normal, {5555, nil}, :init}
    end

    test "can close a connection by returning a stop tuple with a code and nil detail" do
      server = start_mock_server(InitCloseWithCodeAndNilDetailWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [{:close, 5555, nil}] == events
    end

    defmodule InitCloseWithCodeAndDetailWebSock do
      use NoopWebSock
      def init(_opts), do: {:stop, :normal, {5555, "BOOM"}, :init}
    end

    test "can close a connection by returning a stop tuple with a code and detail" do
      server = start_mock_server(InitCloseWithCodeAndDetailWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [{:close, 5555, "BOOM"}] == events
    end

    defmodule InitCloseWithCodeAndDetailAndMessagesWebSock do
      use NoopWebSock

      def init(_opts),
        do: {:stop, :normal, {5555, "BOOM"}, [{:text, "first"}, {:text, "second"}], :init}
    end

    test "can close a connection by returning a stop tuple with a code and detail and messages" do
      server = start_mock_server(InitCloseWithCodeAndDetailAndMessagesWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      events = receive_events(server)

      assert [{:text, "first"}, {:text, "second"}, {:close, 5555, "BOOM"}] == events
    end
  end

  describe "handle_in" do
    defmodule HandleInEchoWebSock do
      use NoopWebSock
      def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    end

    test "can receive a text frame" do
      server = start_mock_server(HandleInEchoWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = receive_events(server) ++ events

      assert [_, {:text, "OK"}] = events
    end

    test "can receive a binary frame" do
      server = start_mock_server(HandleInEchoWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events, ^server} = MockAdapter.send({:binary, "OK"}, server)
      events = receive_events(server) ++ events

      assert [_, {:binary, "OK"}] = events
    end

    defmodule HandleInStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, []}

      def handle_in({"dump", opcode: :text} = data, state),
        do: {:push, {:text, inspect(state)}, [data | state]}

      def handle_in(data, state), do: {:ok, [data | state]}
    end

    test "can return an ok tuple and update state" do
      server = start_mock_server(HandleInStateWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      {:ok, events2, ^server} = MockAdapter.send({:text, "dump"}, server)
      events = receive_events(server) ++ events1 ++ events2

      assert [:handshake_complete, {:text, inspect([{"OK", opcode: :text}])}] == events
    end

    test "can return a push tuple and update state" do
      server = start_mock_server(HandleInStateWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "dump"}, server)
      {:ok, events2, ^server} = MockAdapter.send({:text, "dump"}, server)
      events = receive_events(server) ++ events1 ++ events2

      resp = inspect([{"dump", opcode: :text}])
      assert [_, _, {:text, ^resp}] = events
    end

    defmodule HandleInReplyStateWebSock do
      use NoopWebSock
      def init(_opts), do: {:ok, []}

      def handle_in({"dump", opcode: :text} = data, state),
        do: {:reply, :ok, {:text, inspect(state)}, [data | state]}

      def handle_in(data, state), do: {:ok, [data | state]}
    end

    test "can return a reply tuple and update state" do
      server = start_mock_server(HandleInReplyStateWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "dump"}, server)
      {:ok, events2, ^server} = MockAdapter.send({:text, "dump"}, server)
      events = events1 ++ events2 ++ receive_events(server)

      resp = inspect([{"dump", opcode: :text}])
      assert [_, {:text, ^resp}, _] = events
    end

    defmodule HandleInTextWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:text, "TEXT"}, state}
    end

    test "can return a text frame" do
      server = start_mock_server(HandleInTextWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = receive_events(server) ++ events1

      assert [_, {:text, "TEXT"}] = events
    end

    defmodule HandleInBinaryWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, {:binary, "BINARY"}, state}
    end

    test "can return a binary frame" do
      server = start_mock_server(HandleInBinaryWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:binary, "BINARY"}, server)
      events = receive_events(server) ++ events1

      assert [_, {:binary, "BINARY"}] = events
    end

    # def handle_in(_data, state), do: {:push, {:ping, "PING"}, state}
    # test "can return a ping frame"
    # also for pong

    defmodule HandleInListWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:push, [{:binary, "BINARY"}, {:text, "TEXT"}], state}
    end

    test "can return a list of frames" do
      server = start_mock_server(HandleInListWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = events1 ++ receive_events(server)

      assert [{:binary, "BINARY"}, {:text, "TEXT"}, _] = events
    end

    defmodule HandleInCloseWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:stop, :normal, state}
    end

    test "can close a connection by returning a stop tuple" do
      server = start_mock_server(HandleInCloseWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = events1 ++ receive_events(server)

      assert [{:close, 1000, nil}, _] = events
    end

    # def handle_in(_data, state), do: {:stop, :abnormal, state}
    # test "can close a connection with an error by returning an abnormal stop tuple"

    defmodule HandleInCloseWithCodeWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:stop, :normal, 5555, state}
    end

    test "can close a connection by returning a stop tuple with a code" do
      server = start_mock_server(HandleInCloseWithCodeWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = receive_events(server) ++ events1

      assert [_, {:close, 5555, nil}] = events
    end

    defmodule HandleInCloseWithCodeAndMessagesWebSock do
      use NoopWebSock

      def handle_in(_data, state),
        do: {:stop, :normal, 5555, [{:text, "first"}, {:text, "second"}], state}
    end

    test "can close a connection by returning a stop tuple with a code and messages" do
      server = start_mock_server(HandleInCloseWithCodeAndMessagesWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = receive_events(server) ++ events1

      assert [_, {:text, "first"}, {:text, "second"}, {:close, 5555, nil}] = events
    end

    # def handle_in(_data, state), do: {:stop, {:shutdown, :restart}, state}
    # test "can close a connection by returning an {:shutdown, :restart} tuple"

    defmodule HandleInCloseWithCodeAndNilDetailWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:stop, :normal, {5555, nil}, state}
    end

    test "can close a connection by returning a stop tuple with a code and nil detail" do
      server = start_mock_server(HandleInCloseWithCodeAndNilDetailWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = receive_events(server) ++ events1

      assert [_, {:close, 5555, nil}] = events
    end

    defmodule HandleInCloseWithCodeAndDetailWebSock do
      use NoopWebSock
      def handle_in(_data, state), do: {:stop, :normal, {5555, "BOOM"}, state}
    end

    test "can close a connection by returning a stop tuple with a code and detail" do
      server = start_mock_server(HandleInCloseWithCodeAndDetailWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = receive_events(server) ++ events1
      assert [_, {:close, 5555, "BOOM"}] = events
    end

    defmodule HandleInCloseWithCodeAndDetailAndMessagesWebSock do
      use NoopWebSock

      def handle_in(_data, state),
        do: {:stop, :normal, {5555, "BOOM"}, [{:text, "first"}, {:text, "second"}], state}
    end

    test "can close a connection by returning a stop tuple with a code and detail and messages" do
      server = start_mock_server(HandleInCloseWithCodeAndDetailAndMessagesWebSock)
      {:ok, ^server} = MockAdapter.connect(@mock_uri, [], server: server)

      {:ok, events1, ^server} = MockAdapter.send({:text, "OK"}, server)
      events = receive_events(server) ++ events1

      assert [_, {:text, "first"}, {:text, "second"}, {:close, 5555, "BOOM"}] = events
    end
  end

  # describe "handle_control" do

  # TODO: Convert these as well

  # describe "handle_info" do
  #   defmodule HandleInfoStateWebSock do
  #     use NoopWebSock
  #     def init(_opts), do: {:ok, []}
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info("dump" = data, state), do: {:push, {:text, inspect(state)}, [data | state]}
  #     def handle_info(data, state), do: {:ok, [data | state]}
  #   end

  #   test "can return an ok tuple and update state" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoStateWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

  #     Process.send(pid, "OK", [])
  #     Process.send(pid, "dump", [])

  #     {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
  #     assert response == inspect(["OK"])
  #   end

  #   test "can return a push tuple and update state" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoStateWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()

  #     Process.send(pid, "dump", [])
  #     _ = SimpleWebSocketClient.recv_text_frame(client)
  #     Process.send(pid, "dump", [])

  #     {:ok, response} = SimpleWebSocketClient.recv_text_frame(client)
  #     assert response == inspect(["dump"])
  #   end

  #   defmodule HandleInfoTextWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:push, {:text, "TEXT"}, state}
  #   end

  #   test "can return a text frame" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoTextWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
  #   end

  #   defmodule HandleInfoBinaryWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:push, {:binary, "BINARY"}, state}
  #   end

  #   test "can return a binary frame" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoBinaryWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_binary_frame(client) == {:ok, "BINARY"}
  #   end

  #   defmodule HandleInfoPingWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:push, {:ping, "PING"}, state}
  #   end

  #   test "can return a ping frame" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoPingWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_ping_frame(client) == {:ok, "PING"}
  #   end

  #   defmodule HandleInfoPongWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:push, {:pong, "PONG"}, state}
  #   end

  #   test "can return a pong frame" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoPongWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
  #   end

  #   defmodule HandleInfoListWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:push, [{:pong, "PONG"}, {:text, "TEXT"}], state}
  #   end

  #   test "can return a list of frames" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoListWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_pong_frame(client) == {:ok, "PONG"}
  #     assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "TEXT"}
  #   end

  #   defmodule HandleInfoCloseWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:stop, :normal, state}
  #   end

  #   test "can close a connection by returning a stop tuple" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1000::16>>}
  #     assert SimpleWebSocketClient.connection_closed_for_reading?(client)
  #   end

  #   defmodule HandleInfoAbnormalCloseWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:stop, :abnormal, state}
  #   end

  #   test "can close a connection with an error by returning an abnormal stop tuple" do
  #     output =
  #       capture_log(fn ->
  #         client = SimpleWebSocketClient.tcp_client(context)
  #         SimpleWebSocketClient.http1_handshake(client, HandleInfoAbnormalCloseWebSock)

  #         SimpleWebSocketClient.send_text_frame(client, "whoami")
  #         {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #         pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #         Process.send(pid, "OK", [])

  #         assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1011::16>>}
  #         assert SimpleWebSocketClient.connection_closed_for_reading?(client)
  #         Process.sleep(100)
  #       end)

  #     assert output =~ "(stop) :abnormal"
  #   end

  #   defmodule HandleInfoCloseWithCodeWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:stop, :normal, 5555, state}
  #   end

  #   test "can close a connection by returning a stop tuple with a code" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWithCodeWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
  #     assert SimpleWebSocketClient.connection_closed_for_reading?(client)
  #   end

  #   defmodule HandleInfoCloseWithCodeAndMessagesWebSock do
  #     use NoopWebSock

  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}

  #     def handle_info(_data, state),
  #       do: {:stop, :normal, 5555, [{:text, "first"}, {:text, "second"}], state}
  #   end

  #   test "can close a connection by returning a stop tuple with a code and messages" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWithCodeAndMessagesWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "first"}
  #     assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "second"}
  #     assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
  #     assert SimpleWebSocketClient.connection_closed_for_reading?(client)
  #   end

  #   defmodule HandleInfoCloseWithRestartWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:stop, {:shutdown, :restart}, state}
  #   end

  #   test "can close a connection by returning an {:shutdown, :restart} tuple" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWithRestartWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<1012::16>>}
  #     assert SimpleWebSocketClient.connection_closed_for_reading?(client)
  #   end

  #   defmodule HandleInfoCloseWithCodeAndNilDetailWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:stop, :normal, {5555, nil}, state}
  #   end

  #   test "can close a connection by returning a stop tuple with a code and nil detail" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWithCodeAndNilDetailWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_connection_close_frame(client) == {:ok, <<5555::16>>}
  #     assert SimpleWebSocketClient.connection_closed_for_reading?(client)
  #   end

  #   defmodule HandleInfoCloseWithCodeAndDetailWebSock do
  #     use NoopWebSock
  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}
  #     def handle_info(_data, state), do: {:stop, :normal, {5555, "BOOM"}, state}
  #   end

  #   test "can close a connection by returning a stop tuple with a code and detail" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, HandleInfoCloseWithCodeAndDetailWebSock)

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_connection_close_frame(client) ==
  #              {:ok, <<5555::16, "BOOM"::binary>>}

  #     assert SimpleWebSocketClient.connection_closed_for_reading?(client)
  #   end

  #   defmodule HandleInfoCloseWithCodeAndDetailAndMessagesWebSock do
  #     use NoopWebSock

  #     def handle_in(_data, state), do: {:push, {:text, :erlang.pid_to_list(self())}, state}

  #     def handle_info(_data, state),
  #       do: {:stop, :normal, {5555, "BOOM"}, [{:text, "first"}, {:text, "second"}], state}
  #   end

  #   test "can close a connection by returning a stop tuple with a code and detail and messages",
  #        context do
  #     client = SimpleWebSocketClient.tcp_client(context)

  #     SimpleWebSocketClient.http1_handshake(
  #       client,
  #       HandleInfoCloseWithCodeAndDetailAndMessagesWebSock
  #     )

  #     SimpleWebSocketClient.send_text_frame(client, "whoami")
  #     {:ok, pid} = SimpleWebSocketClient.recv_text_frame(client)
  #     pid = pid |> String.to_charlist() |> :erlang.list_to_pid()
  #     Process.send(pid, "OK", [])

  #     assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "first"}
  #     assert SimpleWebSocketClient.recv_text_frame(client) == {:ok, "second"}

  #     assert SimpleWebSocketClient.recv_connection_close_frame(client) ==
  #              {:ok, <<5555::16, "BOOM"::binary>>}

  #     assert SimpleWebSocketClient.connection_closed_for_reading?(client)
  #   end
  # end

  # describe "terminate" do
  #   setup do
  #     Process.register(self(), __MODULE__)
  #     :ok
  #   end

  #   def send(msg), do: send(__MODULE__, msg)

  #   defmodule TerminateNoImplWebSock do
  #     def init(_), do: {:ok, []}
  #     def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
  #   end

  #   test "callback is optional" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, TerminateNoImplWebSock)

  #     warnings =
  #       capture_log(fn ->
  #         # Get the websock to tell bandit to shut down
  #         SimpleWebSocketClient.send_text_frame(client, "normal")

  #         # Give Bandit a chance to explode if it's going to
  #         Process.sleep(100)
  #       end)

  #     refute warnings =~ "UndefinedFunctionError"
  #   end

  #   defmodule TerminateWebSock do
  #     use NoopWebSock
  #     def handle_in({"normal", opcode: :text}, state), do: {:stop, :normal, state}
  #     def handle_in({"boom", opcode: :text}, state), do: {:stop, :boom, state}
  #     def terminate(reason, _state), do: WebSocketWebSockTest.send(reason)
  #   end

  #   test "is called with :normal on a normal connection shutdown" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

  #     # Get the websock to tell bandit to shut down
  #     SimpleWebSocketClient.send_text_frame(client, "normal")

  #     assert_receive :normal
  #   end

  #   test "is called with {:error, reason} on an error connection shutdown" do
  #     output =
  #       capture_log(fn ->
  #         client = SimpleWebSocketClient.tcp_client(context)
  #         SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

  #         # Get the websock to tell bandit to shut down
  #         SimpleWebSocketClient.send_text_frame(client, "boom")

  #         assert_receive {:error, :boom}
  #         Process.sleep(100)
  #       end)

  #     assert output =~ "(stop) :boom"
  #   end

  #   test "is called with :shutdown on a server shutdown" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

  #     # Shut the server down in an orderly manner
  #     ThousandIsland.stop(context.server_pid)

  #     assert_receive :shutdown
  #   end

  #   test "is called with :remote on a normal remote shutdown" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

  #     SimpleWebSocketClient.send_connection_close_frame(client, 1000)

  #     assert_receive :remote
  #   end

  #   test "is called with {:error, reason} on a protocol error" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

  #     Transport.close(client)

  #     assert_receive {:error, :closed}
  #   end

  #   test "is called with :timeout on a timeout" do
  #     client = SimpleWebSocketClient.tcp_client(context)
  #     SimpleWebSocketClient.http1_handshake(client, TerminateWebSock)

  #     assert_receive :timeout, 1500
  #   end
  # end
end
