xquery version "3.1";

module namespace pt="http://history.state.gov/ns/xquery/twitter/process-tweets";

import module namespace ju = "http://joewiz.org/ns/xquery/json-util" at "json-util.xqm";
import module namespace dates = "http://xqdev.com/dateparser" at "date-parser.xqm";
import module namespace console="http://exist-db.org/xquery/console";
import module namespace functx="http://www.functx.com";

(: for info about each entity type see https://dev.twitter.com/overview/api/entities-in-twitter-objects :)

(: repair known problems with text of tweets :)
declare function pt:clean-text($text as xs:string) {
    replace($text, '&amp;amp;', '&amp;')
};

(: chops a string of text into the bits surrounding an entity :)
declare function pt:chop($text as xs:string, $indices as array(*)) {
    let $index-start := $indices?1
    let $index-end := $indices?2
    let $before := substring($text, 1, $index-start)
    let $after := substring($text, $index-end + 1)
    let $entity := substring($text, $index-start + 1, $index-end - $index-start)
    return
        (
(:        console:log('chopped text into: before: "' || $before || '" entity: "' || $entity || '" after: "' || $after || '"'), :)
        $before, $entity, pt:clean-text($after)
        )
};

(: https://dev.twitter.com/overview/api/entities-in-twitter-objects#urls :)
declare function pt:url($text as xs:string, $url-map as map(*)) {
    let $chunks := pt:chop($text, $url-map?indices)
    let $text := $url-map?display_url
    let $url := $url-map?expanded_url
    return
        ($chunks[1], <a href="{$url}">{$text}</a>, $chunks[3])
};

(: https://dev.twitter.com/overview/api/entities-in-twitter-objects#hashtags :)
declare function pt:hashtag($text as xs:string, $hashtag-map as map(*)) {
    let $chunks := pt:chop($text, $hashtag-map?indices)
    let $text := $hashtag-map?text
    let $url := concat('https://twitter.com/search?q=%23', $text, '&amp;src=hash')
    return
        ($chunks[1], <a href="{$url}">#{$text}</a>, $chunks[3])
};

(: https://dev.twitter.com/overview/api/entities-in-twitter-objects#user_mentions :)
declare function pt:user-mention($text as xs:string, $user-mention-map as map(*)) {
    let $chunks := pt:chop($text, $user-mention-map?indices)
    let $text := $user-mention-map?screen_name
    let $url := concat('https://twitter.com/', $text)
    return
        ($chunks[1], <a href="{$url}">@{$text}</a>, $chunks[3])
};

(: https://dev.twitter.com/overview/api/entities-in-twitter-objects#media :)
declare function pt:photo($text as xs:string, $photo-map as map(*)) {
    let $chunks := pt:chop($text, $photo-map?indices)
    let $text := $photo-map?display_url
    let $url := $photo-map?expanded_url
    return
        ($chunks[1], <a href="{$url}">{$text}</a>, $chunks[3])
};

(: apply entities, from last to first; entities must already be in last-to-first order :)
declare function pt:apply-entities($text as xs:string, $entities as map(*)*, $segments as item()*) {
    if (empty($entities)) then 
        (pt:clean-text($text), $segments)
    else
        let $entity := head($entities)
        let $type := $entity?type
        let $results := 
            if ($type = 'url') then
                pt:url($text, $entity)
            else if ($type = 'hashtag') then
                pt:hashtag($text, $entity)
            else if ($type = 'user-mention') then
                pt:user-mention($text, $entity)
            else if ($type = 'photo') then
                pt:photo($text, $entity)
            else 
                (
                    (: unhandled entity type - no special processing :)
                    pt:chop($text, $entity?indices),
                    console:log('process-tweets error: unknown entity type: ' || $type)
                )
        let $remaining-text := subsequence($results, 1, 1)
        let $remaining-entities := tail($entities)
        let $completed-segments := (subsequence($results, 2), $segments)
        return
            pt:apply-entities($remaining-text, $remaining-entities, $completed-segments)
};

(: sift through the entities and get them into the right order for processing last-to-first.
 : tweet entities are grouped by type, and they do not come in any order with relation to the text,
 : so we need to sort them first before applying them :)
declare function pt:process-entities($tweet as map(*)) {
    let $text := $tweet?text
    let $entities-map := map:get($tweet, 'entities')
    let $entities-to-process :=
        for $entity-key in map:keys($entities-map)
        let $entity := map:get($entities-map, $entity-key)
        return 
            (: drop empty entity arrays :)
            if (array:size($entity) gt 0) then
                switch ($entity-key) 
                    case 'urls' return
                        for $e in $entity?*
                        return
                            map:new(( map {'type': 'url'}, $e ))
                    case 'hashtags' return
                        for $e in $entity?*
                        return
                            map:new(( map {'type': 'hashtag'}, $e ))
                    case 'user_mentions' return
                        for $e in $entity?*
                        return
                            map:new(( map {'type': 'user-mention'}, $e ))
                    case 'media' return
                        for $e in $entity?*
                        return
                            map:new(( map {'type': 'media'}, $e ))
                    default return 
                        (: drop all other entities; we won't process these others.
                         : note that any included entites need an "indices" array :)
                        ()
            else 
                ()
    let $ordered-entities :=
        (: sort by end position of each entity, so we process them from last to first :)
        for $entity in $entities-to-process
        order by $entity?indices?2 descending
        return $entity
    return
        pt:apply-entities($text, $ordered-entities, ())
};

(: Helper functions to recursively create a collection hierarchy. :)

declare function pt:mkcol($collection, $path) {
    pt:mkcol-recursive($collection, tokenize($path, "/"))
};

declare function pt:mkcol-recursive($collection, $components) {
    if (exists($components)) then
        let $newColl := concat($collection, "/", $components[1])
        return (
            xmldb:create-collection($collection, $components[1]),
            pt:mkcol-recursive($newColl, subsequence($components, 2))
        )
    else
        ()
};


(: The primary function for transforming a tweet (as JSON) into XML :)
declare function pt:tweet-json-to-xml($tweet as map(*), $default-screen-name as xs:string?) {
    let $id := $tweet?id_str
    let $screen-name := ($tweet?screen_name, $default-screen-name)[1]
    let $url := concat('https://twitter.com/', $screen-name, '/status/', $id)
    let $text := pt:clean-text($tweet?text)
    let $created-at := $tweet?created_at
    let $created-datetime := adjust-dateTime-to-timezone(xs:dateTime(dates:parseDateTime(replace($created-at, '\+0000 (\d{4})', '$1 0000'))), ())
    let $html := 
        (: "Retweeted tweets are a special kind of tweet", see https://twittercommunity.com/t/long-retweets-are-truncated/9647 :)
        if ($tweet?retweeted) then
            (
                'RT ',
                let $retweeted-user := replace($tweet?text, '^RT @([^:]*?):.*$', '$1')
                let $url := concat('https://twitter.com/', $retweeted-user)
                return
                    <a href="{$url}">@{$retweeted-user}</a>,
                ': ',
                pt:process-entities($tweet?retweeted_status)
            )
        else
            pt:process-entities($tweet)
    return
        <tweet>
            <id>{$id}</id>
            <date>{$created-datetime}</date>
            <screen-name>{$screen-name}</screen-name>
            <url>{$url}</url>
            <text>{$text}</text>
            <html>{$html}</html>
        </tweet>
};

(: Store the transformed tweet into the database :)
declare function pt:store-tweet-xml($tweet-xml) {
    let $screen-name := $tweet-xml/screen-name
    let $created-datetime := xs:dateTime($tweet-xml/date)
    let $year := year-from-date($created-datetime)
    let $month := functx:pad-integer-to-length(month-from-date($created-datetime), 2)
    let $day := functx:pad-integer-to-length(day-from-date($created-datetime), 2)
    let $destination-col := string-join(('/db/apps/twitter/data', $screen-name, $year, $month, $day), '/')
    let $id := $tweet-xml/id
    let $filename := concat($id, '.xml')
    let $prepare-collection := 
        if (xmldb:collection-available($destination-col)) then 
            () 
        else 
            pt:mkcol('/db/apps/twitter/data', string-join(($screen-name, $year, $month, $day), '/'))
    return
        xmldb:store($destination-col, $filename, $tweet-xml)
};