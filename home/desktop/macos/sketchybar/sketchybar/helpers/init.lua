-- Home Manager substitutes the pinned, Nix-built SbarLua directory while
-- assembling the immutable SketchyBar configuration.
package.cpath = package.cpath .. ";@sbarlua@/?.so"
