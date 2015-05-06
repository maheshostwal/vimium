# This file contains the definition of the completers used for the Vomnibox's suggestion UI. A completer will
# take a query (whatever the user typed into the Vomnibox) and return a list of Suggestions, e.g. bookmarks,
# domains, URLs from history.
#
# The Vomnibox frontend script makes a "filterCompleter" request to the background page, which in turn calls
# filter() on each these completers.
#
# A completer is a class which has two functions:
#  - filter(query, onComplete): "query" will be whatever the user typed into the Vomnibox.
#  - refresh(): (optional) refreshes the completer's data source (e.g. refetches the list of bookmarks).

# A Suggestion is a bookmark or history entry which matches the current query.
# It also has an attached "computeRelevancyFunction" which determines how well this item matches the given
# query terms.
class Suggestion
  showRelevancy: true # Set this to true to render relevancy when debugging the ranking scores.

  # - type: one of [bookmark, history, tab].
  # - computeRelevancyFunction: a function which takes a Suggestion and returns a relevancy score
  #   between [0, 1]
  # - extraRelevancyData: data (like the History item itself) which may be used by the relevancy function.
  constructor: (@queryTerms, @type, @url, @title, @computeRelevancyFunction, @extraRelevancyData) ->
    @title ||= ""
    # When @autoSelect is truthy, the suggestion is automatically pre-selected in the vomnibar.
    @autoSelect = false
    # If @noHighlightTerms is falsy, then we don't highlight matched terms in the title and URL.
    @noHighlightTerms = false
    # If @insertText is a string, then the indicated text is inserted into the vomnibar input when the
    # suggestion is selected.
    @insertText = null

  computeRelevancy: -> @relevancy = @computeRelevancyFunction(this)

  generateHtml: ->
    return @html if @html
    relevancyHtml = if @showRelevancy then "<span class='relevancy'>#{@computeRelevancy()}</span>" else ""
    # NOTE(philc): We're using these vimium-specific class names so we don't collide with the page's CSS.
    @html =
      """
      <div class="vimiumReset vomnibarTopHalf">
         <span class="vimiumReset vomnibarSource">#{@type}</span>
         <span class="vimiumReset vomnibarTitle">#{@highlightTerms Utils.escapeHtml @title}</span>
       </div>
       <div class="vimiumReset vomnibarBottomHalf">
        <span class="vimiumReset vomnibarUrl">#{@shortenUrl @highlightTerms Utils.escapeHtml @url}</span>
        #{relevancyHtml}
      </div>
      """

  # Use neat trick to snatch a domain (http://stackoverflow.com/a/8498668).
  getUrlRoot: (url) ->
    a = document.createElement 'a'
    a.href = url
    a.protocol + "//" + a.hostname

  shortenUrl: (url) -> @stripTrailingSlash(url).replace(/^https?:\/\//, "")

  stripTrailingSlash: (url) ->
    url = url.substring(url, url.length - 1) if url[url.length - 1] == "/"
    url

  # Push the ranges within `string` which match `term` onto `ranges`.
  pushMatchingRanges: (string,term,ranges) ->
    textPosition = 0
    # Split `string` into a (flat) list of pairs:
    #   - for i=0,2,4,6,...
    #     - splits[i] is unmatched text
    #     - splits[i+1] is the following matched text (matching `term`)
    #       (except for the final element, for which there is no following matched text).
    # Example:
    #   - string = "Abacab"
    #   - term = "a"
    #   - splits = [ "", "A",    "b", "a",    "c", "a",    b" ]
    #                UM   M       UM   M       UM   M      UM      (M=Matched, UM=Unmatched)
    splits = string.split(RegexpCache.get(term, "(", ")"))
    for index in [0..splits.length-2] by 2
      unmatchedText = splits[index]
      matchedText = splits[index+1]
      # Add the indices spanning `matchedText` to `ranges`.
      textPosition += unmatchedText.length
      ranges.push([textPosition, textPosition + matchedText.length])
      textPosition += matchedText.length

  # Wraps each occurence of the query terms in the given string in a <span>.
  highlightTerms: (string) ->
    return string if @noHighlightTerms
    ranges = []
    escapedTerms = @queryTerms.map (term) -> Utils.escapeHtml(term)
    for term in escapedTerms
      @pushMatchingRanges string, term, ranges

    return string if ranges.length == 0

    ranges = @mergeRanges(ranges.sort (a, b) -> a[0] - b[0])
    # Replace portions of the string from right to left.
    ranges = ranges.sort (a, b) -> b[0] - a[0]
    for [start, end] in ranges
      string =
        string.substring(0, start) +
        "<span class='vomnibarMatch'>#{string.substring(start, end)}</span>" +
        string.substring(end)
    string

  # Merges the given list of ranges such that any overlapping regions are combined. E.g.
  #   mergeRanges([0, 4], [3, 6]) => [0, 6].  A range is [startIndex, endIndex].
  mergeRanges: (ranges) ->
    previous = ranges.shift()
    mergedRanges = [previous]
    ranges.forEach (range) ->
      if previous[1] >= range[0]
        previous[1] = Math.max(range[1], previous[1])
      else
        mergedRanges.push(range)
        previous = range
    mergedRanges


class BookmarkCompleter
  folderSeparator: "/"
  currentSearch: null
  # These bookmarks are loaded asynchronously when refresh() is called.
  bookmarks: null

  filter: (@queryTerms, @onComplete) ->
    @currentSearch = { queryTerms: @queryTerms, onComplete: @onComplete }
    @performSearch() if @bookmarks

  onBookmarksLoaded: -> @performSearch() if @currentSearch

  performSearch: ->
    # If the folder separator character the first character in any query term, then we'll use the bookmark's full path as its title.
    # Otherwise, we'll just use the its regular title.
    usePathAndTitle = @currentSearch.queryTerms.reduce ((prev,term) => prev || term.indexOf(@folderSeparator) == 0), false
    results =
      if @currentSearch.queryTerms.length > 0
        @bookmarks.filter (bookmark) =>
          suggestionTitle = if usePathAndTitle then bookmark.pathAndTitle else bookmark.title
          RankingUtils.matches(@currentSearch.queryTerms, bookmark.url, suggestionTitle)
      else
        []
    suggestions = results.map (bookmark) =>
      suggestionTitle = if usePathAndTitle then bookmark.pathAndTitle else bookmark.title
      new Suggestion(@currentSearch.queryTerms, "bookmark", bookmark.url, suggestionTitle, @computeRelevancy)
    onComplete = @currentSearch.onComplete
    @currentSearch = null
    onComplete(suggestions)

  refresh: ->
    @bookmarks = null
    chrome.bookmarks.getTree (bookmarks) =>
      @bookmarks = @traverseBookmarks(bookmarks).filter((bookmark) -> bookmark.url?)
      @onBookmarksLoaded()

  # If these names occur as top-level bookmark names, then they are not included in the names of bookmark folders.
  ignoreTopLevel:
    'Other Bookmarks': true
    'Mobile Bookmarks': true
    'Bookmarks Bar': true

  # Traverses the bookmark hierarchy, and returns a flattened list of all bookmarks.
  traverseBookmarks: (bookmarks) ->
    results = []
    bookmarks.forEach (folder) =>
      @traverseBookmarksRecursive folder, results
    results

  # Recursive helper for `traverseBookmarks`.
  traverseBookmarksRecursive: (bookmark, results, parent={pathAndTitle:""}) ->
    bookmark.pathAndTitle =
      if bookmark.title and not (parent.pathAndTitle == "" and @ignoreTopLevel[bookmark.title])
        parent.pathAndTitle + @folderSeparator + bookmark.title
      else
        parent.pathAndTitle
    results.push bookmark
    bookmark.children.forEach((child) => @traverseBookmarksRecursive child, results, bookmark) if bookmark.children

  computeRelevancy: (suggestion) ->
    RankingUtils.wordRelevancy(suggestion.queryTerms, suggestion.url, suggestion.title)

class HistoryCompleter
  filter: (queryTerms, onComplete) ->
    @currentSearch = { queryTerms: @queryTerms, onComplete: @onComplete }
    results = []
    HistoryCache.use (history) =>
      results =
        if queryTerms.length > 0
          history.filter (entry) -> RankingUtils.matches(queryTerms, entry.url, entry.title)
        else
          []
      suggestions = results.map (entry) =>
        new Suggestion(queryTerms, "history", entry.url, entry.title, @computeRelevancy, entry)
      onComplete(suggestions)

  computeRelevancy: (suggestion) ->
    historyEntry = suggestion.extraRelevancyData
    recencyScore = RankingUtils.recencyScore(historyEntry.lastVisitTime)
    wordRelevancy = RankingUtils.wordRelevancy(suggestion.queryTerms, suggestion.url, suggestion.title)
    # Average out the word score and the recency. Recency has the ability to pull the score up, but not down.
    score = (wordRelevancy + Math.max(recencyScore, wordRelevancy)) / 2

  refresh: ->

# The domain completer is designed to match a single-word query which looks like it is a domain. This supports
# the user experience where they quickly type a partial domain, hit tab -> enter, and expect to arrive there.
class DomainCompleter
  # A map of domain -> { entry: <historyEntry>, referenceCount: <count> }
  #  - `entry` is the most recently accessed page in the History within this domain.
  #  - `referenceCount` is a count of the number of History entries within this domain.
  #     If `referenceCount` goes to zero, the domain entry can and should be deleted.
  domains: null

  filter: (queryTerms, onComplete) ->
    return onComplete([]) unless queryTerms.length == 1
    if @domains
      @performSearch(queryTerms, onComplete)
    else
      @populateDomains => @performSearch(queryTerms, onComplete)

  performSearch: (queryTerms, onComplete) ->
    query = queryTerms[0]
    domainCandidates = (domain for domain of @domains when domain.indexOf(query) >= 0)
    domains = @sortDomainsByRelevancy(queryTerms, domainCandidates)
    return onComplete([]) if domains.length == 0
    topDomain = domains[0][0]
    onComplete([new Suggestion(queryTerms, "domain", topDomain, null, @computeRelevancy)])

  # Returns a list of domains of the form: [ [domain, relevancy], ... ]
  sortDomainsByRelevancy: (queryTerms, domainCandidates) ->
    results = []
    for domain in domainCandidates
      recencyScore = RankingUtils.recencyScore(@domains[domain].entry.lastVisitTime || 0)
      wordRelevancy = RankingUtils.wordRelevancy(queryTerms, domain, null)
      score = (wordRelevancy + Math.max(recencyScore, wordRelevancy)) / 2
      results.push([domain, score])
    results.sort (a, b) -> b[1] - a[1]
    results

  populateDomains: (onComplete) ->
    HistoryCache.use (history) =>
      @domains = {}
      history.forEach (entry) => @onPageVisited entry
      chrome.history.onVisited.addListener(@onPageVisited.bind(this))
      chrome.history.onVisitRemoved.addListener(@onVisitRemoved.bind(this))
      onComplete()

  onPageVisited: (newPage) ->
    domain = @parseDomainAndScheme newPage.url
    if domain
      slot = @domains[domain] ||= { entry: newPage, referenceCount: 0 }
      # We want each entry in our domains hash to point to the most recent History entry for that domain.
      slot.entry = newPage if slot.entry.lastVisitTime < newPage.lastVisitTime
      slot.referenceCount += 1

  onVisitRemoved: (toRemove) ->
    if toRemove.allHistory
      @domains = {}
    else
      toRemove.urls.forEach (url) =>
        domain = @parseDomainAndScheme url
        if domain and @domains[domain] and ( @domains[domain].referenceCount -= 1 ) == 0
          delete @domains[domain]

  # Return something like "http://www.example.com" or false.
  parseDomainAndScheme: (url) ->
      Utils.hasFullUrlPrefix(url) and not Utils.hasChromePrefix(url) and url.split("/",3).join "/"

  # Suggestions from the Domain completer have the maximum relevancy. They should be shown first in the list.
  computeRelevancy: -> 1

# TabRecency associates a logical timestamp with each tab id.  These are used to provide an initial
# recency-based ordering in the tabs vomnibar (which allows jumping quickly between recently-visited tabs).
class TabRecency
  timestamp: 1
  current: -1
  cache: {}
  lastVisited: null
  lastVisitedTime: null
  timeDelta: 500 # Milliseconds.

  constructor: ->
    chrome.tabs.onActivated.addListener (activeInfo) => @register activeInfo.tabId
    chrome.tabs.onRemoved.addListener (tabId) => @deregister tabId

    chrome.tabs.onReplaced.addListener (addedTabId, removedTabId) =>
      @deregister removedTabId
      @register addedTabId

  register: (tabId) ->
    currentTime = new Date()
    # Register tabId if it has been visited for at least @timeDelta ms.  Tabs which are visited only for a
    # very-short time (e.g. those passed through with `5J`) aren't registered as visited at all.
    if @lastVisitedTime? and @timeDelta <= currentTime - @lastVisitedTime
      @cache[@lastVisited] = ++@timestamp

    @current = @lastVisited = tabId
    @lastVisitedTime = currentTime

  deregister: (tabId) ->
    if tabId == @lastVisited
      # Ensure we don't register this tab, since it's going away.
      @lastVisited = @lastVisitedTime = null
    delete @cache[tabId]

  # Recently-visited tabs get a higher score (except the current tab, which gets a low score).
  recencyScore: (tabId) ->
    @cache[tabId] ||= 1
    if tabId == @current then 0.0 else @cache[tabId] / @timestamp

tabRecency = new TabRecency()

# Searches through all open tabs, matching on title and URL.
class TabCompleter
  filter: (queryTerms, onComplete) ->
    # NOTE(philc): We search all tabs, not just those in the current window. I'm not sure if this is the
    # correct UX.
    chrome.tabs.query {}, (tabs) =>
      results = tabs.filter (tab) -> RankingUtils.matches(queryTerms, tab.url, tab.title)
      suggestions = results.map (tab) =>
        suggestion = new Suggestion(queryTerms, "tab", tab.url, tab.title, @computeRelevancy)
        suggestion.tabId = tab.id
        suggestion
      onComplete(suggestions)

  computeRelevancy: (suggestion) ->
    if suggestion.queryTerms.length
      RankingUtils.wordRelevancy(suggestion.queryTerms, suggestion.url, suggestion.title)
    else
      tabRecency.recencyScore(suggestion.tabId)

class SearchEngineCompleter
  searchEngines: {}

  userIsTyping: ->
    SearchEngines.userIsTyping()

  filter: (queryTerms, onComplete) ->
    { keyword: keyword, url: url, description: description } = @getSearchEngineMatches queryTerms
    custom = url?
    suggestions = []

    mkUrl =
      if custom
        (string) -> url.replace /%s/g, Utils.createSearchQuery string.split /\s+/
      else
        (string) -> Utils.createSearchUrl string.split /\s+/

    haveDescription = description? and 0 < description.trim().length
    type = if haveDescription then description else "search"
    searchUrl = if custom then url else Settings.get "searchUrl"

    # For custom search engines, we add an auto-selected suggestion.
    if custom
      query = queryTerms[1..].join " "
      title = if haveDescription then query else keyword + ": " + query
      suggestions.push @mkSuggestion null, queryTerms, type, mkUrl(query), title, @computeRelevancy, 1
      suggestions[0].autoSelect = true
      queryTerms = queryTerms[1..]
    else
      query = queryTerms.join " "

    if queryTerms.length == 0
      return onComplete suggestions

    onComplete suggestions, (existingSuggestions, onComplete) =>
      suggestions = []
      # For custom search-engine queries, this adds suggestions only if we have a completer.  For other queries,
      # this adds suggestions for the default search engine (if we have a completer for that).

      # Scoring:
      #   - The score does not depend upon the actual suggestion (so, it does not depend upon word
      #     relevancy).  We assume that the completion engine has already factored that in.  Also, completion
      #     engines often handle spelling mistakes, in which case we wouldn't find the query terms in the
      #     suggestion anyway.
      #   - The score is higher if the query term is longer.  The idea is that search suggestions are more
      #     likely to be relevant if, after typing some number of characters, the user hasn't yet found
      #     a useful suggestion from another completer.
      #   - Scores are weighted such that they retain the order provided by the completion engine.
      characterCount = query.length - queryTerms.length + 1
      score = 0.6 * (Math.min(characterCount, 10.0)/10.0)

      if 0 < existingSuggestions.length
        existingSuggestionMinScore = existingSuggestions[existingSuggestions.length-1].relevancy
        if score < existingSuggestionMinScore and MultiCompleter.maxResults <= existingSuggestions.length
          # No suggestion we propose will have a high enough score to beat the existing suggestions, so bail
          # immediately.
          return onComplete []

      CompletionEngines.complete searchUrl, queryTerms, (searchSuggestions = []) =>
        for suggestion in searchSuggestions
          insertText = if custom then "#{keyword} #{suggestion}" else suggestion
          suggestions.push @mkSuggestion insertText, queryTerms, type, mkUrl(suggestion), suggestion, @computeRelevancy, score
          score *= 0.9

        # We keep at least three suggestions (if possible) and at most six.  We keep more than three only if
        # there are enough slots.  The idea is that these suggestions shouldn't wholly displace suggestions
        # from other completers.  That would potentially be a problem because there is no relationship
        # between the relevancy scores produced here and those produced by other completers.
        count = Math.min 6, Math.max 3, MultiCompleter.maxResults - existingSuggestions.length
        onComplete suggestions[...count]

  # FIXME(smblott) Refactor Suggestion constructor as per @mrmr1993's comment in #1635.
  mkSuggestion: (insertText, args...) ->
    suggestion = new Suggestion args...
    extend suggestion, insertText: insertText, noHighlightTerms: true

  # The score is computed in filter() and provided here via suggestion.extraRelevancyData.
  computeRelevancy: (suggestion) -> suggestion.extraRelevancyData

  refresh: ->
    @searchEngines = SearchEngineCompleter.getSearchEngines()

  getSearchEngineMatches: (queryTerms) ->
    (1 < queryTerms.length and @searchEngines[queryTerms[0]]) or {}

  # Static data and methods for parsing the configured search engines.  We keep a cache of the search-engine
  # mapping in @searchEnginesMap.
  @searchEnginesMap: null

  # Parse the custom search engines setting and cache it in SearchEngineCompleter.searchEnginesMap.
  @parseSearchEngines: (searchEnginesText) ->
    searchEnginesMap = SearchEngineCompleter.searchEnginesMap = {}
    for line in searchEnginesText.split /\n/
      tokens = line.trim().split /\s+/
      continue if tokens.length < 2 or tokens[0].startsWith('"') or tokens[0].startsWith("#")
      keywords = tokens[0].split ":"
      continue unless keywords.length == 2 and not keywords[1] # So, like: [ "w", "" ].
      searchEnginesMap[keywords[0]] =
        keyword: keywords[0]
        url: tokens[1]
        description: tokens[2..].join(" ")

  # Fetch the search-engine map, building it if necessary.
  @getSearchEngines: ->
    unless SearchEngineCompleter.searchEnginesMap?
      SearchEngineCompleter.parseSearchEngines Settings.get "searchEngines"
    SearchEngineCompleter.searchEnginesMap

# A completer which calls filter() on many completers, aggregates the results, ranks them, and returns the top
# 10. Queries from the vomnibar frontend script come through a multi completer.
class MultiCompleter
  @maxResults: 10

  constructor: (@completers) ->
    @maxResults = MultiCompleter.maxResults

  refresh: ->
    completer.refresh?() for completer in @completers

  userIsTyping: ->
    completer.userIsTyping?() for completer in @completers

  filter: (queryTerms, onComplete) ->
    # Allow only one query to run at a time.
    if @filterInProgress
      @mostRecentQuery = { queryTerms: queryTerms, onComplete: onComplete }
      return
    RegexpCache.clear()
    @mostRecentQuery = null
    @filterInProgress = true
    suggestions = []
    completersFinished = 0
    continuation = null
    # Call filter() on every source completer and wait for them all to finish before returning results.
    # At most one of the completers (SearchEngineCompleter) may pass a continuation function, which will be
    # called after the results of all of the other completers have been posted.  Any additional results
    # from this continuation will be added to the existing results and posted later.  We don't call the
    # continuation if another query is already waiting.
    for completer in @completers
      do (completer) =>
        Utils.nextTick =>
          completer.filter queryTerms, (newSuggestions, cont = null) =>
            suggestions = suggestions.concat newSuggestions
            continuation = cont if cont?
            if @completers.length <= ++completersFinished
              shouldRunContinuation = continuation? and not @mostRecentQuery
              console.log "skip continuation" if continuation? and not shouldRunContinuation
              # We don't post results immediately if there are none, and we're going to run a continuation
              # (ie. a SearchEngineCompleter).  This prevents hiding the vomnibar briefly before showing it
              # again, which looks ugly.
              unless shouldRunContinuation and suggestions.length == 0
                onComplete @prepareSuggestions queryTerms, suggestions
              # Allow subsequent queries to begin.
              @filterInProgress = false
              if shouldRunContinuation
                continuation suggestions, (newSuggestions) =>
                  onComplete @prepareSuggestions queryTerms, suggestions.concat newSuggestions
              else
                @filter @mostRecentQuery.queryTerms, @mostRecentQuery.onComplete if @mostRecentQuery

  prepareSuggestions: (queryTerms, suggestions) ->
    suggestion.computeRelevancy queryTerms for suggestion in suggestions
    suggestions.sort (a, b) -> b.relevancy - a.relevancy
    suggestions = suggestions[0...@maxResults]
    suggestion.generateHtml() for suggestion in suggestions
    suggestions

# Utilities which help us compute a relevancy score for a given item.
RankingUtils =
  # Whether the given things (usually URLs or titles) match any one of the query terms.
  # This is used to prune out irrelevant suggestions before we try to rank them, and for calculating word relevancy.
  # Every term must match at least one thing.
  matches: (queryTerms, things...) ->
    for term in queryTerms
      regexp = RegexpCache.get(term)
      matchedTerm = false
      for thing in things
        matchedTerm ||= thing.match regexp
      return false unless matchedTerm
    true

  # Weights used for scoring matches.
  matchWeights:
    matchAnywhere:     1
    matchStartOfWord:  1
    matchWholeWord:    1
    # The following must be the sum of the three weights above; it is used for normalization.
    maximumScore:      3
    #
    # Calibration factor for balancing word relevancy and recency.
    recencyCalibrator: 2.0/3.0
    # The current value of 2.0/3.0 has the effect of:
    #   - favoring the contribution of recency when matches are not on word boundaries ( because 2.0/3.0 > (1)/3     )
    #   - favoring the contribution of word relevance when matches are on whole words  ( because 2.0/3.0 < (1+1+1)/3 )

  # Calculate a score for matching term against string.
  # The score is in the range [0, matchWeights.maximumScore], see above.
  # Returns: [ score, count ], where count is the number of matched characters in string.
  scoreTerm: (term, string) ->
    score = 0
    count = 0
    nonMatching = string.split(RegexpCache.get term)
    if nonMatching.length > 1
      # Have match.
      score = RankingUtils.matchWeights.matchAnywhere
      count = nonMatching.reduce(((p,c) -> p - c.length), string.length)
      if RegexpCache.get(term, "\\b").test string
        # Have match at start of word.
        score += RankingUtils.matchWeights.matchStartOfWord
        if RegexpCache.get(term, "\\b", "\\b").test string
          # Have match of whole word.
          score += RankingUtils.matchWeights.matchWholeWord
    [ score, if count < string.length then count else string.length ]

  # Returns a number between [0, 1] indicating how often the query terms appear in the url and title.
  wordRelevancy: (queryTerms, url, title) ->
    urlScore = titleScore = 0.0
    urlCount = titleCount = 0
    # Calculate initial scores.
    for term in queryTerms
      [ s, c ] = RankingUtils.scoreTerm term, url
      urlScore += s
      urlCount += c
      if title
        [ s, c ] = RankingUtils.scoreTerm term, title
        titleScore += s
        titleCount += c

    maximumPossibleScore = RankingUtils.matchWeights.maximumScore * queryTerms.length

    # Normalize scores.
    urlScore /= maximumPossibleScore
    urlScore *= RankingUtils.normalizeDifference urlCount, url.length

    if title
      titleScore /= maximumPossibleScore
      titleScore *= RankingUtils.normalizeDifference titleCount, title.length
    else
      titleScore = urlScore

    # Prefer matches in the title over matches in the URL.
    # In other words, don't let a poor urlScore pull down the titleScore.
    # For example, urlScore can be unreasonably poor if the URL is very long.
    urlScore = titleScore if urlScore < titleScore

    # Return the average.
    (urlScore + titleScore) / 2

    # Untested alternative to the above:
    #   - Don't let a poor urlScore pull down a good titleScore, and don't let a poor titleScore pull down a
    #     good urlScore.
    #
    # return Math.max(urlScore, titleScore)

  # Returns a score between [0, 1] which indicates how recent the given timestamp is. Items which are over
  # a month old are counted as 0. This range is quadratic, so an item from one day ago has a much stronger
  # score than an item from two days ago.
  recencyScore: (lastAccessedTime) ->
    @oneMonthAgo ||= 1000 * 60 * 60 * 24 * 30
    recency = Date.now() - lastAccessedTime
    recencyDifference = Math.max(0, @oneMonthAgo - recency) / @oneMonthAgo

    # recencyScore is between [0, 1]. It is 1 when recenyDifference is 0. This quadratic equation will
    # incresingly discount older history entries.
    recencyScore = recencyDifference * recencyDifference * recencyDifference

    # Calibrate recencyScore vis-a-vis word-relevancy scores.
    recencyScore *= RankingUtils.matchWeights.recencyCalibrator

  # Takes the difference of two numbers and returns a number between [0, 1] (the percentage difference).
  normalizeDifference: (a, b) ->
    max = Math.max(a, b)
    (max - Math.abs(a - b)) / max

# We cache regexps because we use them frequently when comparing a query to history entries and bookmarks,
# and we don't want to create fresh objects for every comparison.
RegexpCache =
  init: ->
    @initialized = true
    @clear()
    # Taken from http://stackoverflow.com/questions/3446170/escape-string-for-use-in-javascript-regex
    @escapeRegExp ||= /[\-\[\]\/\{\}\(\)\*\+\?\.\\\^\$\|]/g

  clear: -> @cache = {}

  # Get rexexp for `string` from cache, creating it if necessary.
  # Regexp meta-characters in `string` are escaped.
  # Regexp is wrapped in `prefix`/`suffix`, which may contain meta-characters (these are not escaped).
  # With their default values, `prefix` and `suffix` have no effect.
  # Example:
  #   - string="go", prefix="\b", suffix=""
  #   - this returns regexp matching "google", but not "agog" (the "go" must occur at the start of a word)
  # TODO: `prefix` and `suffix` might be useful in richer word-relevancy scoring.
  get: (string, prefix="", suffix="") ->
    @init() unless @initialized
    regexpString = string.replace(@escapeRegExp, "\\$&")
    # Avoid cost of constructing new strings if prefix/suffix are empty (which is expected to be a common case).
    regexpString = prefix + regexpString if prefix
    regexpString = regexpString + suffix if suffix
    # Smartcase: Regexp is case insensitive, unless `string` contains a capital letter (testing `string`, not `regexpString`).
    @cache[regexpString] ||= new RegExp regexpString, (if Utils.hasUpperCase(string) then "" else "i")

# Provides cached access to Chrome's history. As the user browses to new pages, we add those pages to this
# history cache.
HistoryCache =
  size: 20000
  history: null # An array of History items returned from Chrome.

  reset: ->
    @history = null
    @callbacks = null

  use: (callback) ->
    return @fetchHistory(callback) unless @history?
    callback(@history)

  fetchHistory: (callback) ->
    return @callbacks.push(callback) if @callbacks
    @callbacks = [callback]
    chrome.history.search { text: "", maxResults: @size, startTime: 0 }, (history) =>
      history.sort @compareHistoryByUrl
      @history = history
      chrome.history.onVisited.addListener(@onPageVisited.bind(this))
      chrome.history.onVisitRemoved.addListener(@onVisitRemoved.bind(this))
      callback(@history) for callback in @callbacks
      @callbacks = null

  compareHistoryByUrl: (a, b) ->
    return 0 if a.url == b.url
    return 1 if a.url > b.url
    -1

  # When a page we've seen before has been visited again, be sure to replace our History item so it has the
  # correct "lastVisitTime". That's crucial for ranking Vomnibar suggestions.
  onPageVisited: (newPage) ->
    i = HistoryCache.binarySearch(newPage, @history, @compareHistoryByUrl)
    pageWasFound = (@history[i].url == newPage.url)
    if pageWasFound
      @history[i] = newPage
    else
      @history.splice(i, 0, newPage)

  # When a page is removed from the chrome history, remove it from the vimium history too.
  onVisitRemoved: (toRemove) ->
    if toRemove.allHistory
      @history = []
    else
      toRemove.urls.forEach (url) =>
        i = HistoryCache.binarySearch({url:url}, @history, @compareHistoryByUrl)
        if i < @history.length and @history[i].url == url
          @history.splice(i, 1)

# Returns the matching index or the closest matching index if the element is not found. That means you
# must check the element at the returned index to know whether the element was actually found.
# This method is used for quickly searching through our history cache.
HistoryCache.binarySearch = (targetElement, array, compareFunction) ->
  high = array.length - 1
  low = 0

  while (low <= high)
    middle = Math.floor((low + high) / 2)
    element = array[middle]
    compareResult = compareFunction(element, targetElement)
    if (compareResult > 0)
      high = middle - 1
    else if (compareResult < 0)
      low = middle + 1
    else
      return middle
  # We didn't find the element. Return the position where it should be in this array.
  return if compareFunction(element, targetElement) < 0 then middle + 1 else middle

root = exports ? window
root.Suggestion = Suggestion
root.BookmarkCompleter = BookmarkCompleter
root.MultiCompleter = MultiCompleter
root.HistoryCompleter = HistoryCompleter
root.DomainCompleter = DomainCompleter
root.TabCompleter = TabCompleter
root.SearchEngineCompleter = SearchEngineCompleter
root.HistoryCache = HistoryCache
root.RankingUtils = RankingUtils
root.RegexpCache = RegexpCache
root.TabRecency = TabRecency
