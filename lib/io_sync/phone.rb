module IoSync
  # One normaliser for both HighLevel and Zoom. Ported from the old
  # IoHl#format_phone and IoZoom#zoom_numbers, tightened so the result is
  # always "+digits" (or digits) and Phonelib-valid.
  module Phone
    module_function

    def normalise(raw)
      return nil if raw.nil?
      value = raw.to_s
      return nil if value.strip.empty? || value.match?(/[A-Za-z]/)
      tel = value.gsub(/\s/, "")
                 .gsub(/\A\[(\d{0,3})\]/, '+\1')
                 .gsub(/\A00/, "+")
                 .gsub(/\A\(\s*44\s*\)/, "+44")
                 .gsub(/\A0/, "+44")
      return nil unless tel.match?(/\A\+?\d+\z/)
      return nil unless Phonelib.valid?(tel)
      tel
    end

    # A landline is shared by a household, so two records holding one is not
    # worth reporting; a mobile is personal. UK mobiles are +44 7…; Phonelib
    # knows the ranges for other countries.
    def mobile?(number)
      (Phonelib.parse(number).types & %i[mobile fixed_or_mobile]).any?
    end
  end
end
