module github.com/twaldin/easl/easld

go 1.26

require (
	github.com/dlclark/regexp2 v1.11.0
	github.com/rivo/uniseg v0.4.7
	github.com/twaldin/easl/conformance v0.0.0-00010101000000-000000000000
	github.com/yuin/goldmark v1.7.17
)

replace github.com/twaldin/easl/conformance => ../conformance
