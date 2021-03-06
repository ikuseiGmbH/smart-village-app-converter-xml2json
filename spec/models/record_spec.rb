require 'rails_helper'

RSpec.describe Record, type: :model do
  describe "import" do
    let(:record) { Record.new }

    it "converts a xml from hash to json" do
      expect(record.convert_to_json({})).to eq("{}")
    end
  end
end
