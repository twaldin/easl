package board

import (
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/route"
	"github.com/twaldin/easl/easld/internal/weblink"
)

// OpenLink is Board.openLink: a web link the user or an agent followed, shown in a browser tile
// beside source. The tile already showing the same address (weblink.Address, compared with each
// browser tile's props.url; a tile in another browser profile, props.profile against the
// `profile` in props, is another page) is returned as it is (existing) and nothing is created;
// otherwise a browser tile with that url and props is placed beside source (Place) and credited
// to caller. url is http(s), spelled as weblink.Parse spells it.
func (b *Board) OpenLink(url, source, caller string, props map[string]any) (o model.Object, existing bool) {
	address, web := weblink.Address(url)
	here, hasSource := b.objects[source]
	profile, hasProfile := props["profile"].(string)
	// Several tiles can show one address (the user made a second on purpose): the nearest.
	distance := func(o model.Object) float64 {
		if !hasSource {
			return 0
		}
		return centerDistance(o.Frame, here.Frame)
	}
	found := false
	var nearest model.Object
	var nearestDistance float64
	for _, o := range b.objects {
		if !web || o.Type != model.Browser {
			continue
		}
		if p, ok := o.Props["profile"].(string); ok != hasProfile || p != profile {
			continue
		}
		shown, ok := o.Props["url"].(string)
		if !ok {
			continue
		}
		if a, ok := weblink.Address(shown); !ok || a != address {
			continue
		}
		d := distance(o)
		if !found || d < nearestDistance || d == nearestDistance && o.ID < nearest.ID {
			found, nearest, nearestDistance = true, o, d
		}
	}
	if found {
		return nearest, true
	}
	all := make(map[string]any, len(props)+1)
	for k, v := range props {
		all[k] = v
	}
	all["url"] = url
	w, h := DefaultSize(model.Browser)
	frame := b.Place(w, h, source, nil, false)
	return b.Create(model.Browser, all, &frame, "", caller), false
}

// centerDistance is Frame.centerDistance: how far a's center is from b's.
func centerDistance(a, b model.Frame) float64 {
	return route.Hypot(a.X+a.W/2-(b.X+b.W/2), a.Y+a.H/2-(b.Y+b.H/2))
}
