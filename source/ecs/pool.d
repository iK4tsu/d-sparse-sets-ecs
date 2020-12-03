module ecs.pool;

import ecs.component;
import ecs.sparseset;

version(unittest) import aurorafw.unit.assertion;


/**
 * Creates a component pool class of an EntityType. \
 * This is similar to SparseSet however with an extra **packed array** with
 *     **components**. This array is kept in sync with the **packed entities**.
 *     Each element belongs to the entity of the **packed entities** array
 *     contained in the same index.
 *
 * Params:
 *     T = valid EntityType.
 *     idBitAmount = a valid number of bits reserved for the id.
 *     C = valid Component.
 *
 * See_Also: $(REF SparseSet, ecs.sparseset)
 */
@safe pure
package final class Pool(T, T idBitAmount, C) : SparseSet!(T, idBitAmount)
	if (isComponent!C)
{
public:
	/**
	 * Associate a component to an entity in the pool.
	 *
	 * Params:
	 *     entity = valid entity to add.
	 *     component = a valid component to add.
	 *
	 * See_Also: $(REF add, ecs.sparseset)
	 */
	@safe pure
	void add(const inout(T) entity, const inout(C) component)
		in (!super.contains(entity))
	{
		packedComponents ~= component;
		super.add(entity);
	}


	/**
	 * Get a component from an entity.
	 *
	 * Params: entity = valid entity to search.
	 *
	 * Returns: a pointer to the respective component.
	 */
	@safe pure
	C* get(const inout(T) entity)
		in (super.contains(entity))
	{
		auto saferef = (() @trusted pure {
			return &packedComponents[entities[idOf(entity)]];
		})();

		return saferef;
	}


	@safe pure @live
	void modify(in T entity, scope ref C component)
		in (super.contains(entity))
	{
		packedComponents[entities[idOf(entity)]] = component;
	}


	/**
	 * Removes an entity from the pool.
	 *
	 * Params: entity = a valid entity to remove.
	 *
	 * See_Also: $(REF remove, ecs.sparseset)
	 */
	@safe pure override
	void remove(const inout(T) entity)
		in (super.contains(entity))
	{
		import std.algorithm : swap;
		import std.range : back, popBack;

		swap(packedComponents.back, packedComponents[entities[idOf(entity)]]);
		packedComponents.popBack();
		super.remove(entity);
	}


private:
	C[] packedComponents;
}


version(unittest)
{
	import ecs.component : Component;
	private @Component struct Position { float x, y; }
	private @Component struct Velocity { float dx, dy; }
	private struct NotComponent {}
}


@system pure
@("pool: add")
unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	Pool!(uint, 20, Position) pool = new Pool!(uint, 20, Position);
	const uint e0 = 0; // simulates an entity with id(0) and batch(0)
	const uint e6 = 6; // simulates an entity with id(6) and batch(0)
	const uint e01 = (1 << 20) | 0; // simulates an entity with id(0) and batch(1)

	assertFalse(__traits(compiles, pool.add(e0, Velocity(0, 0))));

	assertEquals(0, pool.packedComponents.length);

	pool.add(e0, Position(2, 3));
	assertEquals(1, pool.packedComponents.length);

	// in this case we can use the entity directly because we know the batch is 0
	// but internaly only the id of the entity is used as an index
	assertTrue(Position(2, 3) == pool.packedComponents[0]);

	pool.add(e6, Position(4, 5));

	assertEquals(2, pool.packedComponents.length);
	assertTrue(Position(4, 5) == pool.packedComponents[1]);

	assertThrown!AssertError(pool.add(e0, Position(9, 9)));

	pool.add(e01, Position(9, 9)); // same id but diferent batch so it adds

	// now it creates a problem, the new entity was placed at the end of the packedEntities
	// however it's id is the same as e0 and e0 was not removed!
	// if you now remove e0 from this pool this will remove e01 from packedEntities
	// this example will not happen in the actual world because this tested in registry
	// and at this point e0 was already discarded and removed from this pool
	assertEquals(3, pool.packedComponents.length);
	assertTrue(Position(9, 9) == pool.packedComponents[2]);
}


@system pure
@("pool: get")
unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	Pool!(uint, 20, Position) pool = new Pool!(uint, 20, Position);
	const uint e0 = 0; // simulates an entity with id(0) and batch(0)
	const uint e6 = 6; // simulates an entity with id(6) and batch(0)

	pool.add(e0, Position(2, 3));
	assertThrown!AssertError(pool.get(e6));

	Position* position = pool.get(e0);
	assertTrue(*position == Position(2, 3));

	*position = Position(3, 8);

	assertTrue(*position == *pool.get(e0));
	assertTrue(3 == pool.get(e0).x);
	assertTrue(8 == pool.get(e0).y);
}


@safe pure
@("pool: pool initialization")
unittest
{
	assertTrue(__traits(compiles, new Pool!(uint, 20, Position)));
	assertFalse(__traits(compiles, new Pool!(uint, 20, NotComponent)));
}


@system pure
@("pool: remove")
unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	Pool!(uint, 20, Position) pool = new Pool!(uint, 20, Position);
	const uint e0 = 0; // simulates an entity with id(0) and batch(0)
	const uint e6 = 6; // simulates an entity with id(6) and batch(0)
	const uint e61 = (1 << 20) | 6; // simulates an entity with id(6) and batch(1)

	pool.add(e6, Position(2, 5));
	pool.add(e0, Position(8, 8));

	assertTrue(Position(2, 5) == pool.packedComponents[0]);
	assertTrue(Position(8, 8) == pool.packedComponents[1]);

	assertThrown!AssertError(pool.remove(e61));

	// simulate the discard of e6
	pool.remove(e6);

	assertTrue(Position(8, 8) == pool.packedComponents[0]);
	pool.add(e61, Position(17, 15));

	assertTrue(Position(8, 8) == pool.packedComponents[0]);
	assertTrue(Position(17, 15) == pool.packedComponents[1]);
}
