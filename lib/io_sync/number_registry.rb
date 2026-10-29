module IoSync
  # Tracks which Zoom external contact owns each phone number. Seeded from the
  # live Zoom list, then records claim numbers in io_id order, so a number
  # already held by another contact is not duplicated (first come, first served,
  # as the old mirror-table behaviour did by accident).
  class NumberRegistry
    def initialize
      @owners = {}
    end

    def seed(number, owner)
      @owners[number] ||= owner
    end

    def owner(number) = @owners[number]

    # Returns true when the number is free or already owned by this owner.
    def claim(number, owner)
      existing = @owners[number]
      return true if existing.nil? || existing == owner
      false
    ensure
      @owners[number] = owner if @owners[number].nil?
    end

    def release_all(owner)
      @owners.delete_if { |_, o| o == owner }
    end
  end
end
