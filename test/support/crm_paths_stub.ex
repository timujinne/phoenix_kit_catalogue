# CRM is not a dependency of this suite, so the item form's supplier links
# (which reach `PhoenixKitCRM.Paths` through a runtime guard) could never be
# rendered here — which is how a doubled URL prefix shipped. This stub carries
# the two helpers' REAL shapes from phoenix_kit_crm/lib/phoenix_kit_crm/paths.ex:
# `company/1` is already run through `Routes.path/1`, `company_raw/1` is not.
# If phoenix_kit_crm ever becomes a test dependency, delete this file.
if Code.ensure_loaded?(PhoenixKitCRM.Paths) do
  :ok
else
  defmodule PhoenixKitCRM.Paths do
    @moduledoc false
    alias PhoenixKit.Utils.Routes

    @base "/admin/crm"

    def company(uuid) when is_binary(uuid), do: Routes.path("#{@base}/companies/#{uuid}")
    def company_raw(uuid) when is_binary(uuid), do: "#{@base}/companies/#{uuid}"
  end
end
