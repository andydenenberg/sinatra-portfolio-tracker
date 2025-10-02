require 'sinatra'
require 'json'
require 'csv'
require 'net/http'
require 'uri'
require 'rufus-scheduler'
require 'sequel'

set :port, ENV['PORT']
set :bind, '0.0.0.0'

# Initialize database
DB = Sequel.connect(ENV['DATABASE_URL'] || 'postgres://localhost/portfolio_dev')

# Create tables if they don't exist
DB.create_table?(:portfolios) do
  primary_key :id
  String :account
  String :symbol
  Float :quantity
  DateTime :created_at
  DateTime :updated_at
end

DB.create_table?(:snapshots) do
  primary_key :id
  Date :date
  String :data, text: true
  DateTime :created_at
end

scheduler = Rufus::Scheduler.new

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

def load_portfolio
  DB[:portfolios].all.map do |row|
    {
      'account' => row[:account],
      'symbol' => row[:symbol],
      'quantity' => row[:quantity]
    }
  end
end

def save_portfolio(portfolio)
  DB.transaction do
    DB[:portfolios].delete
    portfolio.each do |stock|
      DB[:portfolios].insert(
        account: stock['account'],
        symbol: stock['symbol'],
        quantity: stock['quantity'],
        created_at: Time.now,
        updated_at: Time.now
      )
    end
  end
end

def load_snapshots
  DB[:snapshots].order(:date).all.map do |row|
    {
      'date' => row[:date].to_s,
      'accounts' => JSON.parse(row[:data])
    }
  end
rescue
  []
end

def save_snapshots(snapshots)
  DB.transaction do
    DB[:snapshots].delete
    snapshots.each do |snapshot|
      DB[:snapshots].insert(
        date: snapshot['date'],
        data: snapshot['accounts'].to_json,
        created_at: Time.now
      )
    end
  end
end

def get_accounts(portfolio)
  portfolio.map { |s| s['account'] }.uniq.sort
end

def calculate_account_values(portfolio, fetcher)
  accounts = get_accounts(portfolio)
  accounts.map do |account|
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
end

def take_snapshot
  portfolio = load_portfolio
  return if portfolio.empty?
  fetcher = StockPriceFetcher.new
  account_values = calculate_account_values(portfolio, fetcher)
  snapshots = load_snapshots
  snapshot = {
    'date' => Time.now.strftime('%Y-%m-%d'),
    'accounts' => {}
  }
  account_values.each do |account_data|
    snapshot['accounts'][account_data['account']] = account_data['total_value']
  end
  snapshots.reject! { |s| s['date'] == snapshot['date'] }
  snapshots << snapshot
  snapshots = snapshots.sort_by { |s| s['date'] }.last(90)
  save_snapshots(snapshots)
  puts "Snapshot taken at #{Time.now}"
end

scheduler.cron '0 17 * * * America/Chicago' do
  take_snapshot
end

get '/' do
  portfolio = load_portfolio
  view = params[:view] || 'accounts'
  selected_account = params[:account]
  fetcher = StockPriceFetcher.new
  accounts = get_accounts(portfolio)
  
  if view == 'accounts'
    account_data = calculate_account_values(portfolio, fetcher)
    grand_total_value = account_data.sum { |a| a['total_value'] }
    grand_total_change = account_data.sum { |a| a['total_change'] }
    erb :accounts_view, locals: {
      accounts: account_data,
      grand_total_value: grand_total_value,
      grand_total_change: grand_total_change,
      has_portfolio: !portfolio.empty?,
      all_accounts: accounts
    }
  elsif view == 'history'
    snapshots = load_snapshots
    erb :history_view, locals: {
      snapshots: snapshots,
      has_portfolio: !portfolio.empty?,
      all_accounts: accounts
    }
  elsif view == 'stocks' && selected_account
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
  else
    redirect '/?view=accounts'
  end
end

post '/snapshot' do
  take_snapshot
  redirect '/?view=history'
end

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

post '/clear' do
  save_portfolio([])
  redirect '/'
end

__END__

@@accounts_view
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Stock Portfolio Tracker - Accounts</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;padding:10px}.container{max-width:1200px;margin:0 auto;background:white;border-radius:12px;box-shadow:0 10px 40px rgba(0,0,0,0.2);padding:20px}h1{color:#333;margin-bottom:20px;font-size:1.5rem}.upload-section{background:#f8f9fa;padding:15px;border-radius:8px;margin-bottom:20px}.upload-form{display:flex;gap:10px;align-items:center;flex-wrap:wrap}input[type="file"]{flex:1;min-width:200px;padding:8px;border:2px solid #ddd;border-radius:6px;background:white;font-size:14px}button{padding:8px 16px;background:#667eea;color:white;border:none;border-radius:6px;cursor:pointer;font-size:14px;font-weight:600;transition:background 0.3s;white-space:nowrap}button:hover{background:#5568d3}.clear-btn{background:#dc3545}.clear-btn:hover{background:#c82333}.info{font-size:13px;color:#666;margin-top:10px}.view-selector{background:#f8f9fa;padding:15px;border-radius:8px;margin-bottom:20px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}.view-selector label{font-weight:600;color:#333;font-size:14px}.view-selector a{padding:8px 12px;background:white;color:#667eea;text-decoration:none;border-radius:6px;font-weight:600;transition:all 0.3s;border:2px solid #667eea;font-size:13px}.view-selector a:hover{background:#667eea;color:white}.view-selector a.active{background:#667eea;color:white}.desktop-table{display:table;width:100%;border-collapse:collapse;margin-bottom:20px}.mobile-cards{display:none}.desktop-table th,.desktop-table td{padding:12px;text-align:left;border-bottom:1px solid #eee}.desktop-table th{background:#f8f9fa;font-weight:600;color:#333;text-transform:uppercase;font-size:11px;letter-spacing:0.5px}.desktop-table td{font-size:14px}.account-name{font-weight:600;color:#667eea}.account-name a{color:#667eea;text-decoration:none}.account-name a:hover{text-decoration:underline}.positive{color:#28a745}.negative{color:#dc3545}.right-align{text-align:right}.totals{background:#f8f9fa;padding:20px;border-radius:8px;display:flex;justify-content:space-around;gap:20px;flex-wrap:wrap}.total-item{text-align:center;flex:1;min-width:150px}.total-label{font-size:11px;color:#666;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:5px}.total-value{font-size:22px;font-weight:700}.empty-state{text-align:center;padding:40px 20px;color:#999}.empty-state h2{margin-bottom:10px;color:#666;font-size:1.2rem}@media(max-width:768px){body{padding:5px}.container{padding:15px;border-radius:8px}h1{font-size:1.3rem;margin-bottom:15px}.desktop-table{display:none}.mobile-cards{display:block}.account-card{background:#f8f9fa;border-radius:8px;padding:15px;margin-bottom:12px;border-left:4px solid #667eea}.account-card-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}.account-card-name{font-weight:600;color:#667eea;font-size:16px;text-decoration:none}.account-card-stocks{font-size:12px;color:#666;background:white;padding:4px 8px;border-radius:4px}.account-card-row{display:flex;justify-content:space-between;margin-bottom:8px;font-size:14px}.account-card-label{color:#666;font-size:12px;text-transform:uppercase;letter-spacing:0.5px}.account-card-value{font-weight:600}.totals{padding:15px;gap:15px}.total-value{font-size:20px}.view-selector{padding:10px;gap:8px}.view-selector a{padding:6px 10px;font-size:12px}.view-selector button{padding:6px 10px;font-size:12px}.upload-form{gap:8px}input[type="file"]{font-size:13px;padding:6px}button{padding:8px 12px;font-size:13px}}</style></head><body><div class="container"><h1>📊 Stock Portfolio Tracker</h1><div class="upload-section"><form class="upload-form" action="/upload" method="post" enctype="multipart/form-data"><input type="file" name="file" accept=".csv" required><button type="submit">Upload Portfolio</button><% if has_portfolio %><form action="/clear" method="post" style="display: inline;"><button type="submit" class="clear-btn">Clear Portfolio</button></form><% end %></form><p class="info">Upload a CSV file with columns: account, symbol, quantity</p></div><% if has_portfolio %><div class="view-selector"><label>View:</label><a href="/?view=accounts" class="active">Accounts</a><a href="/?view=history">History</a><form action="/snapshot" method="post" style="display: inline; margin-left: auto;"><button type="submit">Snapshot</button></form></div><table class="desktop-table"><thead><tr><th>Account</th><th class="right-align">Stocks</th><th class="right-align">Total Value</th><th class="right-align">Total Change</th></tr></thead><tbody><% accounts.each do |account| %><tr><td class="account-name"><a href="/?view=stocks&account=<%= URI.encode_www_form_component(account['account']) %>"><%= account['account'] %></a></td><td class="right-align"><%= account['stock_count'] %></td><td class="right-align">$<%= sprintf('%.2f', account['total_value']) %></td><td class="right-align <%= account['total_change'] >= 0 ? 'positive' : 'negative' %>"><%= account['total_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', account['total_change']) %></td></tr><% end %></tbody></table><div class="mobile-cards"><% accounts.each do |account| %><div class="account-card"><div class="account-card-header"><a href="/?view=stocks&account=<%= URI.encode_www_form_component(account['account']) %>" class="account-card-name"><%= account['account'] %></a><span class="account-card-stocks"><%= account['stock_count'] %> stocks</span></div><div class="account-card-row"><span class="account-card-label">Total Value</span><span class="account-card-value">$<%= sprintf('%.2f', account['total_value']) %></span></div><div class="account-card-row"><span class="account-card-label">Change</span><span class="account-card-value <%= account['total_change'] >= 0 ? 'positive' : 'negative' %>"><%= account['total_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', account['total_change']) %></span></div></div><% end %></div><div class="totals"><div class="total-item"><div class="total-label">Grand Total Value</div><div class="total-value">$<%= sprintf('%.2f', grand_total_value) %></div></div><div class="total-item"><div class="total-label">Grand Total Change</div><div class="total-value <%= grand_total_change >= 0 ? 'positive' : 'negative' %>"><%= grand_total_change >= 0 ? '+' : '' %>$<%= sprintf('%.2f', grand_total_change) %></div></div></div><% else %><div class="empty-state"><h2>No Portfolio Loaded</h2><p>Upload a CSV file to get started</p></div><% end %></div></body></html>

@@stocks_view
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Stock Portfolio Tracker - <%= selected_account %></title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;padding:10px}.container{max-width:1200px;margin:0 auto;background:white;border-radius:12px;box-shadow:0 10px 40px rgba(0,0,0,0.2);padding:20px}h1{color:#333;margin-bottom:10px;font-size:1.5rem}h2{color:#667eea;margin-bottom:20px;font-size:1.3rem;font-weight:600}.upload-section{background:#f8f9fa;padding:15px;border-radius:8px;margin-bottom:20px}.upload-form{display:flex;gap:10px;align-items:center;flex-wrap:wrap}input[type="file"]{flex:1;min-width:200px;padding:8px;border:2px solid #ddd;border-radius:6px;background:white;font-size:14px}button{padding:8px 16px;background:#667eea;color:white;border:none;border-radius:6px;cursor:pointer;font-size:14px;font-weight:600;transition:background 0.3s;white-space:nowrap}button:hover{background:#5568d3}.clear-btn{background:#dc3545}.clear-btn:hover{background:#c82333}.info{font-size:13px;color:#666;margin-top:10px}.view-selector{background:#f8f9fa;padding:15px;border-radius:8px;margin-bottom:20px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}.view-selector label{font-weight:600;color:#333;font-size:14px}.view-selector a,.view-selector button{padding:8px 12px;background:white;color:#667eea;text-decoration:none;border-radius:6px;font-weight:600;transition:all 0.3s;border:2px solid #667eea;font-size:13px}.view-selector a:hover,.view-selector button:hover{background:#667eea;color:white}.view-selector a.active{background:#667eea;color:white}.desktop-table{display:table;width:100%;border-collapse:collapse;margin-bottom:20px}.mobile-cards{display:none}.desktop-table th,.desktop-table td{padding:12px;text-align:left;border-bottom:1px solid #eee}.desktop-table th{background:#f8f9fa;font-weight:600;color:#333;text-transform:uppercase;font-size:11px;letter-spacing:0.5px}.desktop-table td{font-size:14px}.symbol{font-weight:600;color:#667eea}.positive{color:#28a745}.negative{color:#dc3545}.right-align{text-align:right}.error-row{color:#dc3545;font-style:italic}.totals{background:#f8f9fa;padding:20px;border-radius:8px;display:flex;justify-content:space-around;gap:20px;flex-wrap:wrap}.total-item{text-align:center;flex:1;min-width:150px}.total-label{font-size:11px;color:#666;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:5px}.total-value{font-size:22px;font-weight:700}@media(max-width:768px){body{padding:5px}.container{padding:15px;border-radius:8px}h1{font-size:1.2rem;margin-bottom:8px}h2{font-size:1.1rem;margin-bottom:15px}.desktop-table{display:none}.mobile-cards{display:block}.stock-card{background:#f8f9fa;border-radius:8px;padding:15px;margin-bottom:12px;border-left:4px solid #667eea}.stock-card-header{margin-bottom:10px}.stock-card-symbol{font-weight:600;color:#667eea;font-size:18px}.stock-card-quantity{font-size:12px;color:#666;margin-top:2px}.stock-card-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}.stock-card-label{font-size:11px;color:#666;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:3px}.stock-card-value{font-weight:600;font-size:14px}.stock-error{color:#dc3545;font-style:italic;font-size:14px}.totals{padding:15px;gap:15px}.total-value{font-size:20px}.view-selector{padding:10px;gap:8px}.view-selector a{padding:6px 10px;font-size:12px}.view-selector button{padding:6px 10px;font-size:12px}.upload-form{gap:8px}input[type="file"]{font-size:13px;padding:6px}button{padding:8px 12px;font-size:13px}}</style></head><body><div class="container"><h1>📊 Stock Portfolio Tracker</h1><h2><%= selected_account %></h2><div class="upload-section"><form class="upload-form" action="/upload" method="post" enctype="multipart/form-data"><input type="file" name="file" accept=".csv" required><button type="submit">Upload Portfolio</button><% if has_portfolio %><form action="/clear" method="post" style="display: inline;"><button type="submit" class="clear-btn">Clear Portfolio</button></form><% end %></form><p class="info">Upload a CSV file with columns: account, symbol, quantity</p></div><div class="view-selector"><label>View:</label><a href="/?view=accounts">Accounts</a><a href="/?view=history">History</a><a href="/?view=stocks&account=<%= URI.encode_www_form_component(selected_account) %>" class="active"><%= selected_account %></a></div><table class="desktop-table"><thead><tr><th>Symbol</th><th class="right-align">Quantity</th><th class="right-align">Current Price</th><th class="right-align">Price Change</th><th class="right-align">Stock Value</th><th class="right-align">Stock Change</th></tr></thead><tbody><% portfolio.each do |stock| %><tr><td class="symbol"><%= stock['symbol'] %></td><% if stock['error'] %><td colspan="5" class="error-row">Error fetching data</td><% else %><td class="right-align"><%= stock['quantity'] %></td><td class="right-align">$<%= sprintf('%.2f', stock['current_price']) %></td><td class="right-align <%= stock['price_change'] >= 0 ? 'positive' : 'negative' %>"><%= stock['price_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', stock['price_change']) %></td><td class="right-align">$<%= sprintf('%.2f', stock['stock_value']) %></td><td class="right-align <%= stock['stock_price_change'] >= 0 ? 'positive' : 'negative' %>"><%= stock['stock_price_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', stock['stock_price_change']) %></td><% end %></tr><% end %></tbody></table><div class="mobile-cards"><% portfolio.each do |stock| %><div class="stock-card"><div class="stock-card-header"><div class="stock-card-symbol"><%= stock['symbol'] %></div><div class="stock-card-quantity"><%= stock['quantity'] %> shares</div></div><% if stock['error'] %><div class="stock-error">Error fetching data</div><% else %><div class="stock-card-grid"><div class="stock-card-item"><div class="stock-card-label">Price</div><div class="stock-card-value">$<%= sprintf('%.2f', stock['current_price']) %></div></div><div class="stock-card-item"><div class="stock-card-label">Change</div><div class="stock-card-value <%= stock['price_change'] >= 0 ? 'positive' : 'negative' %>"><%= stock['price_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', stock['price_change']) %></div></div><div class="stock-card-item"><div class="stock-card-label">Value</div><div class="stock-card-value">$<%= sprintf('%.2f', stock['stock_value']) %></div></div><div class="stock-card-item"><div class="stock-card-label">Total Change</div><div class="stock-card-value <%= stock['stock_price_change'] >= 0 ? 'positive' : 'negative' %>"><%= stock['stock_price_change'] >= 0 ? '+' : '' %>$<%= sprintf('%.2f', stock['stock_price_change']) %></div></div></div><% end %></div><% end %></div><div class="totals"><div class="total-item"><div class="total-label">Account Total Value</div><div class="total-value">$<%= sprintf('%.2f', total_value) %></div></div><div class="total-item"><div class="total-label">Account Total Change</div><div class="total-value <%= total_change >= 0 ? 'positive' : 'negative' %>"><%= total_change >= 0 ? '+' : '' %>$<%= sprintf('%.2f', total_change) %></div></div></div></div></body></html>

@@history_view
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Stock Portfolio Tracker - History</title><script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;padding:10px}.container{max-width:1200px;margin:0 auto;background:white;border-radius:12px;box-shadow:0 10px 40px rgba(0,0,0,0.2);padding:20px}h1{color:#333;margin-bottom:10px;font-size:1.5rem}h2{color:#667eea;margin-bottom:20px;font-size:1.3rem;font-weight:600}.view-selector{background:#f8f9fa;padding:15px;border-radius:8px;margin-bottom:20px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}.view-selector label{font-weight:600;color:#333;font-size:14px}.view-selector a,.view-selector button{padding:8px 12px;background:white;color:#667eea;text-decoration:none;border-radius:6px;font-weight:600;transition:all 0.3s;border:2px solid #667eea;font-size:13px;white-space:nowrap}.view-selector a:hover,.view-selector button:hover{background:#667eea;color:white}.view-selector a.active{background:#667eea;color:white}.chart-container{position:relative;height:400px;margin-bottom:20px}.empty-state{text-align:center;padding:40px 20px;color:#999}.empty-state h2{margin-bottom:10px;color:#666;font-size:1.2rem}.empty-state p{margin-bottom:8px}@media(max-width:768px){body{padding:5px}.container{padding:15px;border-radius:8px}h1{font-size:1.3rem;margin-bottom:8px}h2{font-size:1.1rem;margin-bottom:15px}.chart-container{height:300px}.view-selector{padding:10px;gap:8px}.view-selector a,.view-selector button{padding:6px 10px;font-size:12px}.empty-state{padding:30px 15px}.empty-state h2{font-size:1.1rem}.empty-state p{font-size:14px}}</style></head><body><div class="container"><h1>📊 Stock Portfolio Tracker</h1><h2>Historical Performance</h2><div class="view-selector"><label>View:</label><a href="/?view=accounts">Accounts</a><a href="/?view=history" class="active">History</a><form action="/snapshot" method="post" style="display: inline; margin-left: auto;"><button type="submit">Snapshot</button></form></div><% if snapshots.empty? %><div class="empty-state"><h2>No Historical Data Yet</h2><p>Snapshots will be taken automatically at 5:00 PM CST daily</p><p>Or click "Snapshot" to create your first snapshot</p></div><% else %><div class="chart-container"><canvas id="portfolioChart"></canvas></div><script>const snapshots=<%= snapshots.to_json %>;const dates=snapshots.map(s=>s.date);const allAccounts=new Set();snapshots.forEach(s=>{Object.keys(s.accounts).forEach(acc=>allAccounts.add(acc))});const colors=['rgb(102, 126, 234)','rgb(118, 75, 162)','rgb(237, 100, 166)','rgb(255, 154, 0)','rgb(46, 213, 115)','rgb(0, 184, 217)','rgb(255, 71, 87)','rgb(253, 203, 110)'];const datasets=Array.from(allAccounts).map((account,index)=>{return{label:account,data:snapshots.map(s=>s.accounts[account]||null),borderColor:colors[index%colors.length],backgroundColor:colors[index%colors.length]+'20',borderWidth:window.innerWidth<768?2:3,tension:0.4,fill:false,pointRadius:window.innerWidth<768?2:4,pointHoverRadius:window.innerWidth<768?4:6}});const ctx=document.getElementById('portfolioChart').getContext('2d');const isMobile=window.innerWidth<768;new Chart(ctx,{type:'line',data:{labels:dates,datasets:datasets},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{position:'top',labels:{font:{size:isMobile?11:14,weight:'600'},padding:isMobile?10:20,boxWidth:isMobile?30:40}},title:{display:true,text:'Account Values Over Time',font:{size:isMobile?14:18,weight:'700'},padding:isMobile?10:20},tooltip:{mode:'index',intersect:false,callbacks:{label:function(context){let label=context.dataset.label||'';if(label){label+=': '}if(context.parsed.y!==null){label+='$'+context.parsed.y.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g,',')}return label}}}},scales:{y:{beginAtZero:false,ticks:{callback:function(value){return '$'+(isMobile?(value/1000).toFixed(0)+'k':value.toFixed(0).replace(/\B(?=(\d{3})+(?!\d))/g,','))},font:{size:isMobile?10:12}},grid:{color:'rgba(0, 0, 0, 0.05)'}},x:{ticks:{font:{size:isMobile?9:12},maxRotation:isMobile?45:0,minRotation:isMobile?45:0},grid:{display:false}}},interaction:{mode:'nearest',axis:'x',intersect:false}}})</script><% end %></div></body></html>
