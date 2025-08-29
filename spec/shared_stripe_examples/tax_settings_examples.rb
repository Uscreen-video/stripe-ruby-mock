require 'spec_helper'

shared_examples 'TaxSettings API' do
  it 'retrieves tax settings' do
    settings = Stripe::TaxSettings.retrieve
    expect(settings.object).to eq('tax.settings')
    expect(settings.defaults.tax_behavior).to be_nil
    expect(settings.defaults.tax_code).to eq('txcd_10000000')
    expect(settings.head_office.address.country).to eq('US')
    expect(settings.head_office.address.state).to eq('CA')
    expect(settings.status).to eq('active')
    expect(settings.livemode).to eq(false)
  end
end
