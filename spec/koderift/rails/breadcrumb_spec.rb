require 'spec_helper'

RSpec.describe Koderift::Rails::Breadcrumb do
  include_context 'a captured log'

  it 'is reachable under the Sentry-shaped constant' do
    expect(Koderift::Breadcrumb).to eq described_class
  end

  it 'serialises to the shape Instrumentation already emits' do
    crumb = described_class.new(category: 'payment', message: 'charging', data: { id: 1 })

    expect(crumb.to_h).to include(type: 'payment', message: 'charging', data: { id: 1 })
    expect(crumb.to_h[:timestamp]).to match(/\A\d{4}-\d{2}-\d{2}T/)
  end

  it 'defaults an absent category to manual' do
    expect(described_class.new(message: 'x').to_h[:type]).to eq 'manual'
  end

  it 'rides along on a capture' do
    Koderift.add_breadcrumb(described_class.new(message: 'fetched 12 rows'))
    Koderift.capture_exception(raised)

    expect(last_payload['breadcrumbs'].last['message']).to eq 'fetched 12 rows'
  end

  it 'interleaves with the automatic crumbs collected during a unit of work' do
    result = Koderift::Rails::Instrumentation.capture do
      Koderift.add_breadcrumb(described_class.new(category: 'payment', message: 'charging'))
    end

    expect(result[:breadcrumbs].map { |c| c[:type] }).to eq %w[payment]
  end

  # Outside a captured unit nothing else bounds this array, so a rake task
  # adding crumbs in a loop would otherwise grow it without limit.
  it 'is bounded by max_breadcrumbs even outside a unit of work' do
    Koderift::Rails.configure { |c| c.max_breadcrumbs = 3 }

    5.times { |i| Koderift.add_breadcrumb(described_class.new(message: "crumb #{i}")) }

    trail = Koderift::Rails::Breadcrumbs.current
    expect(trail.size).to eq 3
    expect(trail.first[:message]).to eq 'crumb 2'
  end

  it 'accepts a bare string' do
    Koderift.add_breadcrumb('something happened')

    expect(Koderift::Rails::Breadcrumbs.current.last[:message]).to eq 'something happened'
  end
end
