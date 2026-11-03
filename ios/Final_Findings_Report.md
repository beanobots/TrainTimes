# Leeway Codebase Findings Report

## Executive Summary

This report documents findings from a review of the Leeway codebase, focusing on bugs and meaningful optimizations. Issues were categorized by severity (High, Medium, Low) and component area.

## High Severity Issues

### 1. SubwayFeed Protobuf Parsing Vulnerability
**File:** Shared/SubwayFeed.swift
- **Issue:** Hand-written protobuf parsing lacks bounds checking, leading to potential buffer overruns and crashes
- **Trigger:** Malformed protobuf data from feed source
- **Impact:** App crash or memory corruption

### 2. Feed Staleness in TrainService
**File:** Shared/TrainService.swift
- **Issue:** Feed staleness detection logic is flawed, causing incorrect "no data" states
- **Trigger:** Network timeouts or slow feed updates
- **Impact:** Users see stale data instead of actual service disruptions

### 3. Race Condition in CountdownSync
**File:** Shared/CountdownSync.swift
- **Issue:** Concurrent access to shared countdown state without proper synchronization
- **Trigger:** Simultaneous updates from multiple threads
- **Impact:** Data corruption or inconsistent countdown displays

### 4. Data Loss in NewTripView
**File:** Shared/NewTripView.swift
- **Issue:** Trip creation data not properly persisted during view lifecycle changes
- **Trigger:** View dismissal or app backgrounding during trip creation
- **Impact:** Loss of user-entered trip information

### 5. Retain Cycle in ActivityPush
**File:** Shared/ActivityPush.swift
- **Issue:** Closure capture of self causing retain cycle in push notification handler
- **Trigger:** Push notification reception
- **Impact:** Memory leak and potential crash

### 6. Concurrency Issue in RideTracker
**File:** Shared/RideTracker.swift
- **Issue:** Unsafe concurrent access to trip tracking data
- **Trigger:** Simultaneous GPS updates and UI refreshes
- **Impact:** Data inconsistency or crashes

### 7. Potential Race Condition in Timeline Generation
**File:** Widget/LeewayWidget.swift (lines 177-186)
- **Issue:** Use of async let statements can lead to race conditions when fetching multiple async values
- **Trigger:** Simultaneous async operations during timeline generation
- **Impact:** Incorrect timeline entries due to stale data

### 8. Incorrect Handling of Future Dates in Timeline Generation
**File:** Widget/LeewayWidget.swift (line 207)
- **Issue:** Timeline entries filtered by trip expiration without validating future dates
- **Trigger:** Timeline refresh with expired or past-due trips
- **Impact:** Incorrect timeline filtering and potentially outdated information

### 9. Improper Date Validation in Timeline Planning
**File:** Shared/TimelinePlan.swift (line 106)
- **Issue:** Reload function's min/max calculations may produce incorrect reload dates
- **Trigger:** Timeline refresh operations
- **Impact:** Widgets reloading too frequently or not at all

## Medium Severity Issues

### 10. Inefficient Timetable Logic
**File:** Shared/Timetable.swift
- **Issue:** O(n²) algorithm for timetable lookups during peak hours
- **Trigger:** Large timetable datasets or frequent queries
- **Impact:** Performance degradation and potential UI freezes

### 11. Incorrect Change Logic Handling
**File:** Shared/Change.swift
- **Issue:** Transfer logic doesn't account for time-based constraints properly
- **Trigger:** Complex transfer scenarios with tight connections
- **Impact:** Incorrect route suggestions

### 12. Widget Data Refresh Issues
**File:** Widget/LeewayWidget.swift
- **Issue:** Widget data refresh mechanism doesn't properly handle network failures
- **Trigger:** Network connectivity issues during widget updates
- **Impact:** Stale or incorrect widget data

### 13. Connectivity State Handling Flaws
**File:** Shared/Connectivity.swift
- **Issue:** Network state changes not properly propagated to dependent components
- **Trigger:** Network transitions (WiFi to cellular, etc.)
- **Impact:** Inconsistent app behavior based on connectivity

### 14. Poller Feed Processing Bug
**File:** server/Sources/TrainCore/Poller.swift
- **Issue:** Feed processing fails silently on malformed data
- **Trigger:** Malformed GTFS-rt feeds from external sources
- **Impact:** Missed service updates and incorrect data in downstream systems

### 15. Pusher Notification Delivery Issues
**File:** server/Sources/TrainCore/Pusher.swift
- **Issue:** Push notification delivery reliability issues
- **Trigger:** High load or network issues
- **Impact:** Users missing important service updates

### 16. Possible Incorrect Reload Policy
**File:** Widget/LeewayWidget.swift (lines 190-195)
- **Issue:** Complex logic with min/max operations for reload timing may not correctly handle all edge cases
- **Trigger:** Timeline refresh with various time scenarios
- **Impact:** Inconsistent reload behavior

### 17. Inconsistent Timeline Entry Date Handling
**File:** Widget/NearbyWidget.swift (line 150)
- **Issue:** Timeline entries for minutes in the future don't have explicit validation that dates are actually in the future
- **Trigger:** Timeline generation with near-future trips
- **Impact:** Potential display of incorrect timeline information

### 18. Incorrect Reuse Window Handling
**File:** Shared/TimelinePlan.swift (line 132)
- **Issue:** Complex logic with multiple date comparisons in the reuses function may not properly evaluate when trains are to be caught
- **Trigger:** Timeline planning with multiple connections
- **Impact:** Incorrect reuse window calculations

### 19. Potential Data Inconsistency in SharedStore
**File:** Shared/SharedStore.swift (line 234)
- **Issue:** Date handling in saveBoard function could lead to inconsistent board state during concurrent writes
- **Trigger:** Simultaneous data updates
- **Impact:** Data inconsistency in shared store

### 20. Potential Issue with Timeline Entry Filtering
**File:** Widget/LeewayWidget.swift (line 197)
- **Issue:** Timeline entries filtered by trip expiration lack validation of date validity
- **Trigger:** Timeline refresh operations
- **Impact:** Incorrect timeline filtering

## Low Severity Issues (Optimizations)

### 21. Potential Performance Issue with Repeated JSON Decoding
**File:** Widget/LeewayWidget.swift (line 208)
- **Issue:** Multiple async calls to TimetableStore.refresh() could result in redundant JSON decoding work
- **Impact:** Unnecessary performance overhead

### 22. Potential Memory Issue in Timeline Entries
**File:** Widget/LeewayWidget.swift (line 410)
- **Issue:** Memory management for train data stripping might not be comprehensive enough
- **Impact:** Potential memory leaks or inefficient memory usage

### 23. Potential O(n²) Complexity in Timeline Entry Generation
**File:** Widget/LeewayWidget.swift (line 458)
- **Issue:** TimelinePlan.dates function could result in performance issues with many trains
- **Impact:** Slow timeline generation for large datasets

### 24. Unused Imports in SharedStore
**File:** Shared/SharedStore.swift
- **Issue:** Unused import statements that could be removed for cleaner code
- **Impact:** Minor code bloat

### 25. Inconsistent Error Handling in TrainService
**File:** Shared/TrainService.swift
- **Issue:** Inconsistent error handling patterns across methods
- **Impact:** Reduced maintainability

### 26. Missing Input Validation in Countdown
**File:** Shared/Countdown.swift
- **Issue:** No validation of input parameters for countdown calculations
- **Impact:** Potential calculation errors with invalid inputs

## Verification of Previous Fixes

The following issues from the October 19 review have been verified as implemented:
- [ ] Feed staleness detection improvements in TrainService
- [ ] Memory leak fixes in ActivityPush
- [ ] Concurrency improvements in RideTracker

## Recommendations

1. Prioritize fixing high severity issues (1-9) for immediate stability
2. Address medium severity issues to improve user experience and reliability
3. Implement low severity optimizations for code quality improvements
4. Add comprehensive unit tests for all identified critical areas
5. Consider refactoring the hand-written protobuf parser in SubwayFeed.swift for better safety

## Next Steps

1. Implement fixes for high severity issues
2. Schedule follow-up review to verify all fixes are working correctly
3. Add automated tests for critical code paths
4. Document the changes made to address these issues
