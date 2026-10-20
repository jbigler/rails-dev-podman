# frozen_string_literal: true

module Wt
  module Msg
    # stale: installed unit files that no longer match their templates ([] = all current).
    class UnitFilesChecked < Data.define(:stale)
      include Message
      def apply(model) = model.with(stale_units: stale)
    end
  end
end
