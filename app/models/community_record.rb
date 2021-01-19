class CommunityRecord < ApplicationRecord
  serialize :json_data, JSON
end
