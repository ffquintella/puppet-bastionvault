# frozen_string_literal: true

# Resolves the UID of the bastionvault rootless user, if it already exists.
# Returns nil on the first Puppet run (before the user is created); the
# cgroups class handles that case gracefully.
Facter.add(:bastionvault_user_uid) do
  confine kernel: 'Linux'
  setcode do
    require 'etc'
    begin
      Etc.getpwnam('bastionvault').uid
    rescue ArgumentError
      nil
    end
  end
end
