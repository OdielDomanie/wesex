defmodule Wesex do
  @moduledoc """
  Using (`use`) this module does the following:

  * `use GenServer`
  * defines overridable `init/1`
    * Requires a keyword list:
      * `cb_state`
      * `callbacks`
      * `url`
      * `adapter`, defaults to `Wesex.MintAdapter`
      * `headers`, defaults to `[]`
      * `adapter_opts`, defaults to []
    * Sets `trap_exit` process flag
    * Calls `Wesex.Connection.connect/5`.
      * **Returns** `{:ok, Wesex.Connection.t()}` if successful,
        or `{:stop, reason}` if `connect` returns error

  * defines overridable `handle_info/2`.
    This feeds received messages to `Wesex.Connection.event/2` to mutate the state.
    Returns `false` instead of a valid callback return value if the message is not a
    connection event.

  * defines overridable `terminate/2` that starts the closing handshake and
    continues to process received messages until the connection is closed.

  The defines GenServer has `Wesex.Connection.t` as its state.

  When overriden, the functions should always call `super` as well.
  """

  alias Wesex.MintAdapter
  alias __MODULE__.Connection

  defmacro __using__(arg) do
    quote do
      alias Wesex.Connection

      use GenServer, unquote(arg)

      @impl GenServer
      def init(opts) do
        Process.flag(:trap_exit, true)

        cb_state = Keyword.fetch!(opts, :cb_state)
        callbacks = Keyword.fetch!(opts, :callbacks)
        adapter = opts[:adapter] || MintAdapter
        url = Keyword.fetch!(opts, :url)
        headers = opts[:headers] || []
        adapter_opts = opts[:adapter_opts] || []

        case Connection.connect(adapter, {callbacks, cb_state}, url, headers, adapter_opts) do
          {:ok, conn} ->
            {:ok, conn}

          {:error, reason} ->
            {:stop, reason}
        end
      end

      @impl GenServer
      def handle_info(msg, conn) do
        case Connection.event(conn, msg) do
          %Connection{} = conn ->
            if Connection.short_status(conn) == :closed do
              {:stop, :normal, conn}
            else
              {:noreply, conn}
            end

          false ->
            false
        end
      end

      @impl GenServer
      def terminate(reason, %Connection{} = con) do
        con =
          if Connection.short_status(con) in [:handshaking, :open] do
            Connection.close(con, 1000, nil)
          else
            con
          end

        recv_until_closed(con)
      end

      defp recv_until_closed(%Connection{status: :closed}), do: :ok

      defp recv_until_closed(%Connection{} = con) do
        receive do
          msg ->
            case Connection.event(con, msg) do
              false -> recv_until_closed(con)
              %Connection{} = con -> recv_until_closed(con)
            end
        end
      end

      defoverridable init: 1, handle_info: 2, terminate: 2
    end
  end
end
