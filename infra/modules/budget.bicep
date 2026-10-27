metadata description = 'Monthly Azure budget with actual-cost alerts at 50, 80, and 100 percent (ADR 0016, C2).'

@description('Budget name.')
param name string

@description('Monthly amount in the billing currency.')
@minValue(1)
param amount int

@description('First day of the budget period (yyyy-MM-01).')
param startDate string

@description('Email addresses that receive the alerts.')
@minLength(1)
param contactEmails string[]

var thresholds = [
  50
  80
  100
]

resource budget 'Microsoft.Consumption/budgets@2026-06-01' = {
  name: name
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: '${startDate}T00:00:00Z'
    }
    notifications: toObject(
      thresholds,
      threshold => 'actual${threshold}',
      threshold => {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: threshold
        thresholdType: 'Actual'
        contactEmails: contactEmails
      }
    )
  }
}

@description('Resource ID of the budget.')
output id string = budget.id
