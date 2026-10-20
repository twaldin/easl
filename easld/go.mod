module github.com/twaldin/easl/easld

go 1.26.0

require (
	github.com/clipperhouse/uax29/v2 v2.7.0
	github.com/dlclark/regexp2 v1.11.0
	github.com/rivo/uniseg v0.4.7
	github.com/twaldin/easl/conformance v0.0.0-00010101000000-000000000000
	github.com/yuin/goldmark v1.7.17
	golang.org/x/net v0.55.0
	golang.org/x/sys v0.45.0
	golang.org/x/text v0.37.0
)

require golang.org/x/image v0.41.0

replace github.com/twaldin/easl/conformance => ../conformance
