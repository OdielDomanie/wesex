defmodule Wesex.DummyAdapter do
  @moduledoc """
  Dummy adapter that runs against a WebSock (v0.5.3) implementation in-process.

  At `c:Wesex.Adapter.connect/4`,
  `:websock_impl` and (optionally) `:websock_init_arg` options must be given.

  Only `c:WebSock.handle_in/2` and `c:WebSock.init/1` callbacks are called.
  """
  @behaviour Wesex.Adapter

  @type ws :: :ws
  @type con :: %{
          optional(:error_on_next_send) => reason :: any,
          opts: keyword(),
          open: boolean(),
          remote: %{
            ref: reference(),
            websock: module,
            websock_state: any,
            open: boolean(),
            ws: :open | :close_sent | :closed
          }
        }

  def websocket, do: :ws

  @impl true
  def encode(:ws, {:enc_error, reason} = _frame) do
    {:error, :ws, reason}
  end

  def encode(:ws, frame) do
    {:ok, :ws, :erlang.term_to_binary([frame])}
  end

  @impl true
  def decode(:ws, data) do
    case :erlang.binary_to_term(data) do
      frames when is_list(frames) ->
        {:ok, :ws, frames}

      {:error, reason} ->
        {:error, :ws, reason}
    end
  end

  @impl true
  def stream_request_body(con, _reference, _iodata)
      when con.open and con.error_on_next_send != nil do
    reason = con.error_on_next_send

    con =
      con
      |> put_in([:open], :closed)
      |> put_in([:remote, :open], false)
      |> put_in([:remote, :ws], :closed)
      |> put_in([:error_on_next_send], nil)

    {:error, con, reason}
  end

  def stream_request_body(con, reference, iodata) when con.open do
    frames = :erlang.binary_to_term(IO.iodata_to_binary(iodata))
    send_in_frames(frames, con, reference)
  end

  def stream_request_body(con, _reference, _iodata) do
    {:error, con, :not_open}
  end

  @impl true
  def stream(con, msg) do
    ref = con.remote.ref

    try do
      :erlang.binary_to_term(msg)
    rescue
      ArgumentError -> :unknown
    else
      {^ref, :con_closed} ->
        {:ok, %{con | open: false}, []}

      {^ref, :upgrade_resp} ->
        resps = [
          {:status, ref, 101},
          {:headers, ref, []},
          {:done, ref}
        ]

        {:ok, con, resps}

      {^ref, frames} ->
        frames_bin = :erlang.term_to_binary(frames)
        {:ok, con, [{:data, ref, frames_bin}]}

      _ ->
        :unknown
    end
  end

  @impl true
  def open?(con, _) do
    con.open
  end

  @impl true
  # :websock_impl, :websock_init_arg
  def connect(scheme, _addr, _port, opts) when scheme in [:http, :https] do
    if reason = opts[:error] do
      {:error, reason}
    else
      con = %{
        open: true,
        opts: opts,
        remote: %{
          websock: opts[:websock_impl],
          open: true,
          ws: :closed
        }
      }

      {:ok, con}
    end
  end

  @impl true
  def close(con) do
    con =
      con
      |> put_in([:open], false)
      |> put_in([:remote, :open], false)
      |> put_in([:remote, :status], :closed)

    {:ok, con}
  end

  @impl true
  def upgrade(scheme, con, _path, _headers, opts) when scheme in [:ws, :wss] do
    if reason = opts[:error] do
      {:error, con, reason}
    else
      ref = make_ref()

      send(self(), :erlang.term_to_binary({ref, :upgrade_resp}))

      init_handle_result = con.remote.websock.init(con.opts[:websock_init_arg])

      con =
        con
        |> put_in([:remote, :status], :open)
        |> put_in([:remote, :ref], ref)
        |> put_in([:remote, :websock_state], nil)

      con = do_handle_result(init_handle_result, con, ref)

      {:ok, con, ref}
    end
  end

  @impl true
  def new(con, _reference, _response_status, _response_headers, _keyword) do
    {:ok, con, :ws}
  end

  defp send_in_frames([], con, _ref), do: {:ok, con}

  defp send_in_frames(_, con, _ref)
       when not con.remote.open do
    {:error, %{con | open: false}, :closed}
  end

  defp send_in_frames([{:ping, _} | rest], con, ref) when con.remote.open do
    send_pong(ref)
    send_in_frames(rest, con, ref)
  end

  defp send_in_frames([:ping | rest], con, ref) when con.remote.open do
    send_pong(ref)
    send_in_frames(rest, con, ref)
  end

  defp send_in_frames([{:close, _code, _reason} | _rest], con, ref)
       when con.remote.open and con.remote.status == :sent_close do
    con = con |> put_in([:remote, :open], false) |> put_in([:remote, :status], :closed)
    send(self(), :erlang.term_to_binary({ref, :con_closed}))
    {:ok, con}
  end

  defp send_in_frames([{:close, code, _reason} | _rest], con, ref)
       when con.remote.open and con.remote.status == :open do
    send_close(code, "", ref)
    con = con |> put_in([:remote, :open], false) |> put_in([:remote, :status], :closed)
    send(self(), :erlang.term_to_binary({ref, :con_closed}))
    {:ok, con}
  end

  defp send_in_frames([_ | rest], con, ref)
       when con.remote.open and con.remote.status == :sent_close do
    send_in_frames(rest, con, ref)
  end

  defp send_in_frames([{binary_or_text, data} | rest], con, ref)
       when con.remote.open and con.remote.status == :open and binary_or_text in [:text, :binary] do
    handle_result =
      con.remote.websock.handle_in({data, opcode: binary_or_text}, con.remote.websock_state)

    con = do_handle_result(handle_result, con, ref)

    send_in_frames(rest, con, ref)
  end

  defp do_handle_result(handle_result, con, ref) do
    case handle_result do
      {:push, msgs, websock_state} ->
        msgs = if is_list(msgs), do: msgs, else: [msgs]
        send_msgs(msgs, ref)
        put_in(con.remote.websock_state, websock_state)

      {:reply, _, msgs, websock_state} ->
        msgs = if is_list(msgs), do: msgs, else: [msgs]
        send_msgs(msgs, ref)
        put_in(con.remote.websock_state, websock_state)

      {:ok, websock_state} ->
        put_in(con.remote.websock_state, websock_state)

      {:stop, _, websock_state} ->
        send_close(1000, nil, ref)

        put_in(con.remote.websock_state, websock_state)
        |> put_in([:remote, :open], false)
        |> put_in([:remote, :status], :closed)

      {:stop, _reason, {int, reason}, websock_state} ->
        send_close(int, reason, ref)

        put_in(con.remote.websock_state, websock_state)
        |> put_in([:remote, :open], false)
        |> put_in([:remote, :status], :closed)

      {:stop, _reason, int, websock_state} ->
        send_close(int, nil, ref)

        put_in(con.remote.websock_state, websock_state)
        |> put_in([:remote, :open], false)
        |> put_in([:remote, :status], :closed)

      {:stop, _reason, {int, reason}, msgs, websock_state} ->
        msgs = if is_list(msgs), do: msgs, else: [msgs]
        send_msgs(msgs, ref)
        send_close(int, reason, ref)

        put_in(con.remote.websock_state, websock_state)
        |> put_in([:remote, :open], false)
        |> put_in([:remote, :status], :closed)

      {:stop, _reason, int, msgs, websock_state} ->
        msgs = if is_list(msgs), do: msgs, else: [msgs]
        send_msgs(msgs, ref)
        send_close(int, nil, ref)

        put_in(con.remote.websock_state, websock_state)
        |> put_in([:remote, :open], false)
        |> put_in([:remote, :status], :closed)
    end
  end

  defp send_msgs(data_frames, ref) do
    bin = :erlang.term_to_binary({ref, data_frames})
    send(self(), bin)
    :ok
  end

  defp send_close(code, reason, ref) do
    :erlang.term_to_binary({ref, [{:close, code, reason}]}) |> (&send(self(), &1)).()
    :ok
  end

  defp send_pong(ref) do
    :erlang.term_to_binary({ref, [{:pong, ""}]}) |> (&send(self(), &1)).()
    :ok
  end
end
