# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AsyncEventApi do
  it "owns the public execution/recovery facade while Agent::Base owns no duplicate methods" do
    public_api = %i[
      invoke invoke_async stream stream_async
      approve approve_async resolve resolve_async
    ]
    owners = public_api.to_h do |name|
      [name, Phronomy::Agent::Base.instance_method(name).owner]
    end
    expect(owners).to eq(public_api.to_h { |name| [name, described_class] })
    expect(Phronomy::Agent::Base.public_instance_methods(false) & public_api).to be_empty
  end
end
