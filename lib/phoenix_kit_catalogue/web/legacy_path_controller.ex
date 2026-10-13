defmodule PhoenixKitCatalogue.Web.LegacyPathController do
  @moduledoc """
  Sends the module's old admin addresses on to the current ones.

  The pages lived under `/admin/catalogue` — singular, while the module is
  "Catalogues" everywhere a person reads it. They are under
  `/admin/catalogues` now, and this keeps what still points at the old
  address working: bookmarks, links in sent mail and in the activity log,
  and sibling modules released before the change. The settings page moved
  the same way, from `/admin/settings/catalogue` to
  `/admin/settings/catalogues`.

  The rest of the path, the locale and URL prefix in front of it, and the
  query string all carry over. Characters a redirect target may not hold
  are percent-encoded in the query, which a reader decodes back to the
  same value; a path holding one is no page of this module and gets a 404.

  Admin-only, like the module's other HTTP route: a signed-out visitor is
  sent to log in, not told where the admin pages live.

  ## A renamed admin area

  A host may rename `/admin` (`config :phoenix_kit, admin_path:`), and core
  rewrites every route to the configured segment — these included, so on a
  host that calls it `/backoffice` the old address arrives as
  `/backoffice/catalogue`. The moves are therefore written canonically and
  put through `Routes.apply_admin_segment/1` before they are looked for;
  matching the literal `/admin/…` would find nothing there and redirect the
  request to itself, permanently.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Utils.Routes

  plug(PhoenixKitWeb.Users.Auth, :phoenix_kit_require_admin)

  # Canonical: `/admin` here is the name in code, never the configured one.
  @moves [
    {"/admin/settings/catalogue", "/admin/settings/catalogues"},
    {"/admin/catalogue", "/admin/catalogues"}
  ]

  # What `Phoenix.Controller.redirect/2` refuses in a local target by
  # raising, plus the line breaks a response header cannot carry.
  @unsafe_in_target ["\\", "/%09", "/\t", "\r", "\n"]

  @doc """
  301 to the current address, or 404 when the request is not for an old one
  or its address cannot be a redirect target — never a redirect to the
  address it came in on, and never an exception.
  """
  @spec forward(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def forward(conn, _params) do
    with {:ok, to} <- target(conn.request_path, conn.query_string),
         false <- String.contains?(to, @unsafe_in_target) do
      conn |> put_status(:moved_permanently) |> redirect(to: to)
    else
      _unchanged_or_unsafe -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  @doc """
  The current address for an old one: `{:ok, path}`, or `:unchanged` when
  `path` holds none of the old addresses.

  Only the module's own segment changes, and only where it is a whole
  segment — `/admin/catalogue-x` and an address already under
  `/admin/catalogues` are `:unchanged`.
  """
  @spec target(String.t(), String.t() | nil) :: {:ok, String.t()} | :unchanged
  def target(path, query \\ "") do
    # The router ignores empty segments, so `//host/admin/catalogue` matches
    # and `request_path` still starts with two slashes — a target `redirect/2`
    # refuses as a protocol-relative URL, raising a 500 instead of answering.
    path = "/" <> String.trim_leading(path, "/")

    moves =
      Map.new(@moves, fn {old, new} ->
        {Routes.apply_admin_segment(old), Routes.apply_admin_segment(new)}
      end)

    pattern = moves |> Map.keys() |> Enum.map_join("|", &Regex.escape/1)

    moved =
      Regex.replace(~r{(?:#{pattern})(?=/|$)}, path, &Map.fetch!(moves, &1), global: false)

    cond do
      moved == path -> :unchanged
      query in [nil, ""] -> {:ok, moved}
      true -> {:ok, moved <> "?" <> encode_unsafe(query)}
    end
  end

  # Percent-encodes what a redirect target may not hold. Each replacement
  # decodes back to the character it stands for, so the page behind the
  # redirect reads the query the request carried.
  defp encode_unsafe(query) do
    query
    |> String.replace("\\", "%5C")
    |> String.replace("\t", "%09")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
    |> String.replace("/%09", "%2F%09")
  end
end
