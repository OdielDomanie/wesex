defmodule Wesex.Adapter do
  @moduledoc """
  The behaviour for the connection adapter for `Wesex.Connection`.
  """
  alias Wesex.Connection

  @type state :: any

  @callback connect(url :: URI.t(), headers :: [{String.t(), String.t()}], opts :: Keyword.t()) ::
              {:ok, state()} | {:error, reason :: any}
  @callback event(raw_event :: any, state()) :: {[Connection.adapter_event()], state()} | false
  @callback send_pong(binary(), state) :: {[Connection.adapter_event()], state()}
  @callback send_ping(state) :: {[Connection.adapter_event()], state()}
  @callback local_close(code_reason :: {1000..4999, nil | binary()}, state()) ::
              {[Connection.adapter_event()], state()}
  @callback abort(state) :: {[Connection.adapter_event()], state()}
  @callback send(message :: {:text | :binary, binary()}, state()) ::
              {:ok, [Connection.adapter_event()], state()}
              | {:error, [Connection.adapter_event()], state(), reason :: any}
end
