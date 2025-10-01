require 'sinatra'
require 'json'
require 'csv'
require 'net/http'
require 'uri'

# Configure Sinatra
# set :port, ENV['PORT'] || 4567
set :port, ENV['PORT']
set :bind, '0.0.0.0'

# Data storage file
PORTFOLIO_FILE = 'portfolio_data.json'

# Stock price fetcher class
class StockPriceFetcher
  def initialize
    @headers = {
      'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    }
  end

  def get_stock_price(ticker_symbol)
    url = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{ticker_symbol}")
    
    begin
      response = fetch_with_redirect(url)
      
      return nil unless response.is_a?(Net::HTTPSuccess)
      
      data = JSON.parse(response.body)
      return nil if data['chart']['error']
      
      result = data['chart']['result'][0]
      meta = result['meta']
      
      current_price = meta['regularMarketPrice']
      previous_close = meta['previousClose'] || meta['chartPreviousClose']
      
      price_change = current_price - previous_close
      
      {
        'current_price' => current_price.round(2),
        'price_change' => price_change.round(2)
      }
    rescue
      nil
    end
  end

  private

  def fetch_with_redirect(url, limit = 5)
    return nil if limit == 0
    
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true
    http.read_timeout = 10
    
    request = Net::HTTP::Get.new(url)
    @headers.each { |key, value| request[key] = value }
    
    response = http.request(request)
    
    case response
    when Net::HTTPRedirection
      new_url = URI(response['location'])
      fetch_with_redirect(new_url, limit - 1)
    else
      response
    end
  end
end

# Load portfolio from file
def load_portfolio
  return [] unless File.exist?(PORTFOLIO_FILE)
  JSON.parse(File.read(PORTFOLIO_FILE))
rescue
  []
end

# Save portfolio to file
def save_portfolio(portfolio)
  File.write(PORTFOLIO_FILE, JSON.pretty_generate(portfolio))
end

# Get unique accounts
def get_accounts(portfolio)
  portfolio.map { |s| s['account'] }.uniq.sort
end

# Main page
get '/' do
  portfolio = load_portfolio
  view = params[:view] || 'accounts'
  selected_account = params[:account]
  
  fetcher = StockPriceFetcher.new
  accounts = get_accounts(portfolio)
  
  if view == 'accounts'
    # Show account summary
    account_data = accounts.map do |account|
      account_stocks = portfolio.select { |s| s['account'] == account }
      
      stocks_with_prices = account_stocks.map do |stock|
        price_data = fetcher.get_stock_price(stock['symbol'])
        next nil unless price_data
        
        quantity = stock['quantity'].to_f
        current_price = price_data['current_price']
        price_change = price_data['price_change']
        
        {
          'stock_value' => (quantity * current_price).round(2),
          'stock_price_change' => (quantity * price_change).round(2)
        }
      end.compact
      
      total_value = stocks_with_prices.sum { |s| s['stock_value'] }
      total_change = stocks_with_prices.sum { |s| s['stock_price_change'] }
      
      {
        'account' => account,
        'total_value' => total_value,
        'total_change' => total_change,
        'stock_count' => account_stocks.length
      }
    end
    
    grand_total_value = account_data.sum { |a| a['total_value'] }
    grand_total_change = account_data.sum { |a| a['total_change'] }
    
    erb :accounts_view, locals: {
      accounts: account_data,
      grand_total_value: grand_total_value,
      grand_total_change: grand_total_change,
      has_portfolio: !portfolio.empty?,
      all_accounts: accounts
    }
  else
    # Show individual account stocks
    account_stocks = portfolio.select { |s| s['account'] == selected_account }
    
    portfolio_data = account_stocks.map do |stock|
      symbol = stock['symbol']
      quantity = stock['quantity'].to_f
      
      price_data = fetcher.get_stock_price(symbol)
      
      if price_data
        current_price = price_data['current_price']
        price_change = price_data['price_change']
        stock_value = (quantity * current_price).round(2)
        stock_price_change = (quantity * price_change).round(2)
        
        {
          'symbol' => symbol,
          'quantity' => quantity,
          'current_price' => current_price,
          'price_change' => price_change,
          'stock_value' => stock_value,
          'stock_price_change' => stock_price_change
        }
      else
        {
          'symbol' => symbol,
          'quantity' => quantity,
          'error' => true
        }
      end
    end
    
    total_value = portfolio_data.sum { |s| s['stock_value'] || 0 }
    total_change = portfolio_data.sum { |s| s['stock_price_change'] || 0 }
    
    erb :stocks_view, locals: {
      portfolio: portfolio_data,
      total_value: total_value,
      total_change: total_change,
      has_portfolio: !portfolio.empty?,
      all_accounts: accounts,
      selected_account: selected_account
    }
  end
end

# Upload CSV
post '/upload' do
  return redirect '/' unless params[:file]
  
  file = params[:file][:tempfile]
  portfolio = []
  
  CSV.foreach(file, headers: true) do |row|
    account = row['account']&.strip
    symbol = row['symbol']&.strip&.upcase
    quantity = row['quantity']&.strip&.to_f
    
    next unless account && symbol && quantity && quantity > 0
    
    portfolio << {
      'account' => account,
      'symbol' => symbol,
      'quantity' => quantity
    }
  end
  
  save_portfolio(portfolio)
  redirect '/'
end

# Clear portfolio
post '/clear' do
  save_portfolio([])
  redirect '/'
end

__END__

@@accounts_view
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Stock Portfolio Tracker - Accounts</title>
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      padding: 20px;
    }
    
    .container {
      max-width: 1200px;
      margin: 0 auto;
      background: white;
      border-radius: 12px;
      box-shadow: 0 10px 40px rgba(0,0,0,0.2);
      padding: 30px;
    }
    
    h1 {
      color: #333;
      margin-bottom: 30px;
      font-size: 2rem;
    }
    
    .upload-section {
      background: #f8f9fa;
      padding: 20px;
      border-radius: 8px;
      margin-bottom: 30px;
    }
    
    .upload-form {
      display: flex;
      gap: 10px;
      align-items: center;
      flex-wrap: wrap;
    }
    
    input[type="file"] {
      flex: 1;
      min-width: 200px;
      padding: 10px;
      border: 2px solid #ddd;
      border-radius: 6px;
      background: white;
    }
    
    button {
      padding: 10px 20px;
      background: #667eea;
      color: white;
      border: none;
      border-radius: 6px;
      cursor: pointer;
      font-size: 14px;
      font-weight: 600;
      transition: background 0.3s;
    }
    
    button:hover {
      background: #5568d3;
    }
    
    .clear-btn {
      background: #dc3545;
    }
    
    .clear-btn:hover {
      background: #c82333;
    }
    
    .info {
      font-size: 14px;
      color: #666;
      margin-top: 10px;
    }
    
    .view-selector {
      background: #f8f9fa;
      padding: 15px 20px;
      border-radius: 8px;
      margin-bottom: 30px;
      display: flex;
      gap: 15px;
      align-items: center;
    }
    
    .view-selector label {
      font-weight: 600;
      color: #333;
    }
    
    .view-selector a {
      padding: 8px 16px;
      background: white;
      color: #667eea;
      text-decoration: none;
      border-radius: 6px;
      font-weight: 600;
      transition: all 0.3s;
      border: 2px solid #667eea;
    }
    
    .view-selector a:hover {
      background: #667eea;
      color: white;
    }
    
    .view-selector a.active {
      background: #667eea;
      color: white;
    }
    
    table {
      width: 100%;
      border-collapse: collapse;
      margin-bottom: 20px;
    }
    
    th, td {
      padding: 12px;
      text-align: left;
      border-bottom: 1px solid #eee;
    }
    
    th {
      background: #f8f9fa;
      font-weight: 600;
      color: #333;
      text-transform: uppercase;
      font-size: 12px;
      letter-spacing: 0.5px;
    }
    
    td {
      font-size: 14px;
    }
    
    .account-name {
      font-weight: 600;
      color: #667eea;
    }
    
    .account-name a {
      color: #667eea;
      text-decoration: none;
    }
    
    .account-name a:hover {
      text-decoration: underline;
    }
    
    .positive {
      color: #28a745;
    }
    
    .negative {
      color: #dc3545;
    }
    
    .totals {
      background: #f8f9fa;
      padding: 20px;
      border-radius: 8px;
      display: flex;
      justify-content: space-around;
      gap: 20px;
    }
    
    .total-item {
      text-align: center;
    }
    
    .total-label {
      font-size: 12px;
      color: #666;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 5px;
    }
    
    .total-value {
      font-size: 24px;
      font-weight: 700;
    }
    
    .empty-state {
      text-align: center;
      padding: 60px 20px;
      color: #999;
    }
    
    .empty-state h2 {
      margin-bottom: 10px;
      color: #666;
    }
    
    .right-align {
      text-align: right;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>📊 Stock Portfolio Tracker</h1>
    
    <div class="upload-section">
      <form class="upload-form" action="/upload" method="post" enctype="multipart/form-data">
        <input type="file" name="file" accept=".csv" required>
        <button type="submit">Upload Portfolio</button>
        <% if has_portfolio %>
          <form action="/clear" method="post" style="display: inline;">
            <button type="submit" class="clear-btn">Clear Portfolio</button>
          </form>
        <% end %>
      </form>
      <p class="info">Upload a CSV file with columns: account, symbol, quantity</p>
    </div>
    
    <% if has_portfolio %>
      <div class="view-selector">
        <label>View:</label>
        <a href="/?view=accounts" class="active">Accounts Summary</a>
      </div>
      
      <table>
        <thead>
          <tr>
            <th>Account</th>
            <th class="right-align">Stocks</th>
            <th class="right-align">Total Value</th>
            <th class="right-align">Total Change</th>
          </tr>
        </thead>
        <tbody>
          <% accounts.each do |account| %>
            <tr>
              <td class="account-name">
                <a href="/?view=stocks&account=<%= URI.encode_www_form_component(account['account']) %>">
                  <%= account['account'] %>
                </a>
              </td>
              <td class="right-align"><%= account['stock_count'] %></td>
              <td class="right-align">$<%= sprintf('%.2f', account['total_value']) %></td>
              <td class="right-align <%= account['total_change'] >= 0 ? 'positive' : 'negative' %>">
                <%= account['total_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', account['total_change']) %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
      
      <div class="totals">
        <div class="total-item">
          <div class="total-label">Grand Total Value</div>
          <div class="total-value">$<%= sprintf('%.2f', grand_total_value) %></div>
        </div>
        <div class="total-item">
          <div class="total-label">Grand Total Change</div>
          <div class="total-value <%= grand_total_change >= 0 ? 'positive' : 'negative' %>">
            <%= grand_total_change >= 0 ? '+' : '' %>$<%= sprintf('%.2f', grand_total_change) %>
          </div>
        </div>
      </div>
    <% else %>
      <div class="empty-state">
        <h2>No Portfolio Loaded</h2>
        <p>Upload a CSV file to get started</p>
      </div>
    <% end %>
  </div>
</body>
</html>

@@stocks_view
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Stock Portfolio Tracker - <%= selected_account %></title>
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      padding: 20px;
    }
    
    .container {
      max-width: 1200px;
      margin: 0 auto;
      background: white;
      border-radius: 12px;
      box-shadow: 0 10px 40px rgba(0,0,0,0.2);
      padding: 30px;
    }
    
    h1 {
      color: #333;
      margin-bottom: 10px;
      font-size: 2rem;
    }
    
    h2 {
      color: #667eea;
      margin-bottom: 30px;
      font-size: 1.5rem;
      font-weight: 600;
    }
    
    .upload-section {
      background: #f8f9fa;
      padding: 20px;
      border-radius: 8px;
      margin-bottom: 30px;
    }
    
    .upload-form {
      display: flex;
      gap: 10px;
      align-items: center;
      flex-wrap: wrap;
    }
    
    input[type="file"] {
      flex: 1;
      min-width: 200px;
      padding: 10px;
      border: 2px solid #ddd;
      border-radius: 6px;
      background: white;
    }
    
    button {
      padding: 10px 20px;
      background: #667eea;
      color: white;
      border: none;
      border-radius: 6px;
      cursor: pointer;
      font-size: 14px;
      font-weight: 600;
      transition: background 0.3s;
    }
    
    button:hover {
      background: #5568d3;
    }
    
    .clear-btn {
      background: #dc3545;
    }
    
    .clear-btn:hover {
      background: #c82333;
    }
    
    .info {
      font-size: 14px;
      color: #666;
      margin-top: 10px;
    }
    
    .view-selector {
      background: #f8f9fa;
      padding: 15px 20px;
      border-radius: 8px;
      margin-bottom: 30px;
      display: flex;
      gap: 15px;
      align-items: center;
    }
    
    .view-selector label {
      font-weight: 600;
      color: #333;
    }
    
    .view-selector a {
      padding: 8px 16px;
      background: white;
      color: #667eea;
      text-decoration: none;
      border-radius: 6px;
      font-weight: 600;
      transition: all 0.3s;
      border: 2px solid #667eea;
    }
    
    .view-selector a:hover {
      background: #667eea;
      color: white;
    }
    
    .view-selector a.active {
      background: #667eea;
      color: white;
    }
    
    table {
      width: 100%;
      border-collapse: collapse;
      margin-bottom: 20px;
    }
    
    th, td {
      padding: 12px;
      text-align: left;
      border-bottom: 1px solid #eee;
    }
    
    th {
      background: #f8f9fa;
      font-weight: 600;
      color: #333;
      text-transform: uppercase;
      font-size: 12px;
      letter-spacing: 0.5px;
    }
    
    td {
      font-size: 14px;
    }
    
    .symbol {
      font-weight: 600;
      color: #667eea;
    }
    
    .positive {
      color: #28a745;
    }
    
    .negative {
      color: #dc3545;
    }
    
    .totals {
      background: #f8f9fa;
      padding: 20px;
      border-radius: 8px;
      display: flex;
      justify-content: space-around;
      gap: 20px;
    }
    
    .total-item {
      text-align: center;
    }
    
    .total-label {
      font-size: 12px;
      color: #666;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 5px;
    }
    
    .total-value {
      font-size: 24px;
      font-weight: 700;
    }
    
    .error-row {
      color: #dc3545;
      font-style: italic;
    }
    
    .right-align {
      text-align: right;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>📊 Stock Portfolio Tracker</h1>
    <h2><%= selected_account %></h2>
    
    <div class="upload-section">
      <form class="upload-form" action="/upload" method="post" enctype="multipart/form-data">
        <input type="file" name="file" accept=".csv" required>
        <button type="submit">Upload Portfolio</button>
        <% if has_portfolio %>
          <form action="/clear" method="post" style="display: inline;">
            <button type="submit" class="clear-btn">Clear Portfolio</button>
          </form>
        <% end %>
      </form>
      <p class="info">Upload a CSV file with columns: account, symbol, quantity</p>
    </div>
    
    <div class="view-selector">
      <label>View:</label>
      <a href="/?view=accounts">Accounts Summary</a>
      <a href="/?view=stocks&account=<%= URI.encode_www_form_component(selected_account) %>" class="active">
        <%= selected_account %> Stocks
      </a>
    </div>
    
    <table>
      <thead>
        <tr>
          <th>Symbol</th>
          <th class="right-align">Quantity</th>
          <th class="right-align">Current Price</th>
          <th class="right-align">Price Change</th>
          <th class="right-align">Stock Value</th>
          <th class="right-align">Stock Change</th>
        </tr>
      </thead>
      <tbody>
        <% portfolio.each do |stock| %>
          <tr>
            <td class="symbol"><%= stock['symbol'] %></td>
            <% if stock['error'] %>
              <td colspan="5" class="error-row">Error fetching data</td>
            <% else %>
              <td class="right-align"><%= stock['quantity'] %></td>
              <td class="right-align">$<%= sprintf('%.2f', stock['current_price']) %></td>
              <td class="right-align <%= stock['price_change'] >= 0 ? 'positive' : 'negative' %>">
                <%= stock['price_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', stock['price_change']) %>
              </td>
              <td class="right-align">$<%= sprintf('%.2f', stock['stock_value']) %></td>
              <td class="right-align <%= stock['stock_price_change'] >= 0 ? 'positive' : 'negative' %>">
                <%= stock['stock_price_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', stock['stock_price_change']) %>
              </td>
            <% end %>
          </tr>
        <% end %>
      </tbody>
    </table>
    
    <div class="totals">
      <div class="total-item">
        <div class="total-label">Account Total Value</div>
        <div class="total-value">$<%= sprintf('%.2f', total_value) %></div>
      </div>
      <div class="total-item">
        <div class="total-label">Account Total Change</div>
        <div class="total-value <%= total_change >= 0 ? 'positive' : 'negative' %>">
          <%= total_change >= 0 ? '+' : '' %>$<%= sprintf('%.2f', total_change) %>
        </div>
      </div>
    </div>
  </div>
</body>
</html>