defmodule MishkaDocumentWeb.ExamplePreviewController do
  @moduledoc """
  Answers `/_preview/doc-example/:kind/:id/:index` with `MishkaDocumentWeb.Live.ExamplePreview`: one
  example of a page of a document, or of one of its notes, drawn alone and live, for the frame of
  the kit's `doc-example` Preview dialog.

  `kind` is `section` or `note`, `id` a UUID and `index` a whole number; anything else is the 404
  every missing page is. The LiveView is handed, signed into the page, the example's source, the
  visitor's session as the CMS's runtime pages are handed it and the response's CSP nonce
  (`MishkaCmsCore.Runtime.CspNonce`).

  ## Headers

  The response is never indexed: `x-robots-tag: noindex, nofollow`, beside the robots tag the page
  carries and the `Disallow: /_preview/` of the site's robots.txt.

  It is served its own Content-Security-Policy, enforced whatever the site's own mode is, and no
  report-only one:

    * `default-src 'self'`, `base-uri 'none'`, `object-src 'none'`, `form-action 'self'`;
    * `frame-ancestors 'self'` — only a page of the site itself may frame it — beside the
      `x-frame-options: SAMEORIGIN` the site's pipeline already sends;
    * `script-src 'self'` and this response's nonce, and no host;
    * `connect-src 'self'` and the LiveView socket of the address asked, `ws://` and `wss://`;
    * `img-src`, `media-src`, `font-src`, `frame-src`, `style-src`, `style-src-elem` and
      `style-src-attr` as the site's own policy for this response says, so the example draws what
      it draws on the page and nothing more; when the site sends none, `'self'` — with `data:`
      for an image and a font, the nonce for a style element, and a style attribute as
      `MishkaCmsWeb.Runtime.Plugs.SecurityHeaders.inline_style_allowed?/0` answers.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.CspNonce
  alias MishkaCmsWeb.Runtime.Plugs.SecurityHeaders

  @kinds ~w(section note)

  @kept ~w(img-src media-src font-src frame-src style-src style-src-elem style-src-attr)

  @host ~r/\A[A-Za-z0-9.\-]+(?::\d{1,5})?\z|\A\[[0-9A-Fa-f:.]+\](?::\d{1,5})?\z/

  def show(conn, %{"kind" => kind, "id" => id, "index" => index}) do
    with true <- kind in @kinds,
         {:ok, id} <- Ecto.UUID.cast(id),
         true <- Regex.match?(~r/\A\d{1,6}\z/, index) do
      conn
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
      |> put_resp_header("content-security-policy", policy(conn))
      |> delete_resp_header("content-security-policy-report-only")
      |> Phoenix.LiveView.Controller.live_render(MishkaDocumentWeb.Live.ExamplePreview,
        session: session(conn, "#{kind}/#{id}/#{String.to_integer(index)}")
      )
    else
      _not_an_example -> raise NotFoundError, message: "Example not found"
    end
  end

  # The session `MishkaCmsWeb.RuntimeLive` is handed, with the example's source and the nonce.
  defp session(conn, source) do
    conn
    |> AshAuthentication.Phoenix.LiveSession.generate_session(nil, [])
    |> Map.merge(CspNonce.session(conn))
    |> Map.put("source", source)
  end

  defp policy(conn) do
    nonce = nonce_source(conn.assigns[:csp_nonce])
    site = site_directives(conn)

    [
      {"default-src", "'self'"},
      {"base-uri", "'none'"},
      {"object-src", "'none'"},
      {"frame-ancestors", "'self'"},
      {"form-action", "'self'"},
      {"script-src", Enum.join(["'self'" | nonce], " ")},
      {"connect-src", Enum.join(["'self'" | socket_sources(conn)], " ")}
    ]
    |> Enum.concat(for name <- @kept, do: {name, Map.get(site, name, fallback(name, nonce))})
    |> Enum.map_join("; ", fn {name, value} -> name <> " " <> value end)
  end

  defp nonce_source(nonce) when is_binary(nonce), do: ["'nonce-#{nonce}'"]
  defp nonce_source(_none), do: []

  # The directives of the policy the site's pipeline put on this response, enforced or reported.
  defp site_directives(conn) do
    (get_resp_header(conn, "content-security-policy") ++
       get_resp_header(conn, "content-security-policy-report-only"))
    |> Enum.take(1)
    |> Enum.flat_map(&String.split(&1, ";"))
    |> Enum.map(&String.split(String.trim(&1), ~r/\s+/, parts: 2))
    |> Enum.reduce(%{}, fn
      [name, value], found -> Map.put_new(found, String.downcase(name), value)
      _empty, found -> found
    end)
  end

  defp fallback("img-src", _nonce), do: "'self' data:"
  defp fallback("font-src", _nonce), do: "'self' data:"
  defp fallback("style-src-elem", nonce), do: Enum.join(["'self'" | nonce], " ")

  defp fallback("style-src", _nonce), do: Enum.join(["'self'" | inline_style()], " ")

  defp fallback("style-src-attr", _nonce),
    do: (inline_style() == [] && "'none'") || "'unsafe-inline'"

  defp fallback(_name, _nonce), do: "'self'"

  defp inline_style,
    do: (SecurityHeaders.inline_style_allowed?() && ["'unsafe-inline'"]) || []

  # The LiveView socket of the host the browser asked, as its `Host` header names it.
  defp socket_sources(conn) do
    case get_req_header(conn, "host") do
      [host | _rest] ->
        if Regex.match?(@host, host), do: ["ws://" <> host, "wss://" <> host], else: []

      [] ->
        []
    end
  end
end
