module BlindReviews
  module CandidateLabel
    module_function

    def for(index)
      raise ArgumentError, "Candidate index must be nonnegative" if index.negative?

      suffix = +""
      number = index

      loop do
        suffix.prepend(("A".ord + (number % 26)).chr)
        number = (number / 26) - 1
        break if number.negative?
      end

      "Candidate #{suffix}"
    end
  end
end
