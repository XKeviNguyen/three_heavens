# Geometry and wording for shared/_score_board: a half-circle gauge for the
# average of all candidates and a bar per candidate. Positions are SVG
# attributes, not inline styles, which the content security policy blocks.
module ScoreBoardHelper
  GAUGE_CENTER = [ 60, 60 ].freeze
  GAUGE_RADIUS = 48
  # Five equal arcs from low (left) to high (right), with a small gap between.
  GAUGE_SEGMENTS = %w[#ef4444 #f97316 #facc15 #84cc16 #10b981].freeze
  GAUGE_GAP = 0.012
  BANDS = {
    "poor" => "bg-red-100 text-red-800",
    "weak" => "bg-amber-100 text-amber-800",
    "fair" => "bg-amber-100 text-amber-900",
    "good" => "bg-emerald-100 text-emerald-800",
    "excellent" => "bg-emerald-100 text-emerald-900"
  }.freeze

  def score_fraction(value, scale)
    (value - scale.min).fdiv(scale.max - scale.min).clamp(0.0, 1.0)
  end

  def score_band(fraction)
    BANDS.keys.fetch([ (fraction * BANDS.size).floor, BANDS.size - 1 ].min)
  end

  def score_band_classes(fraction)
    BANDS.fetch(score_band(fraction))
  end

  def formatted_score(value)
    number_with_precision(value, precision: 1, locale: :en)
  end

  # 0.0 is the left end of the half circle, 1.0 the right end.
  def gauge_point(fraction)
    angle = Math::PI * fraction
    [ (GAUGE_CENTER[0] - GAUGE_RADIUS * Math.cos(angle)).round(2), (GAUGE_CENTER[1] - GAUGE_RADIUS * Math.sin(angle)).round(2) ]
  end

  def gauge_segments
    GAUGE_SEGMENTS.each_with_index.map do |color, index|
      from = gauge_point(index.fdiv(GAUGE_SEGMENTS.size) + (index.zero? ? 0 : GAUGE_GAP))
      to = gauge_point((index + 1).fdiv(GAUGE_SEGMENTS.size) - (index == GAUGE_SEGMENTS.size - 1 ? 0 : GAUGE_GAP))
      [ "M #{from.join(" ")} A #{GAUGE_RADIUS} #{GAUGE_RADIUS} 0 0 1 #{to.join(" ")}", color ]
    end
  end
end
