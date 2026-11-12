. as $cur
| ($cur | map(.uuid)) as $have
| ($cur + [ $seed[0][] | select((.uuid as $u | ($have | index($u))) == null) ])
| map(
    . as $e
    | ( [ $seed[0][] | select(.uuid == $e.uuid) ] ) as $s
    | if (($e.name == null) or ($e.name == "")) and ($s[0].name != null)
      then $e + {name: $s[0].name}
      else $e
      end
  )
