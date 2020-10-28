module ecs.sparseset;

import ecs.entity : isEntityType, isValidBitIdAmount;

version(unittest) import aurorafw.unit.assertion;


/**
 * Creates a sarse set class of an EntityType.
 * A sparse set is formed with two arrays, a sparse and a packed arrays.
 * The indices of the sparse array are the keys for access to the value on the
 *     packed array. \
 * \
 * The value which resides in an index of the sparse array
 *     corresponds to the index of the packed array where the data is stored.
 * Similar to a Hash-Map but faster if you're using only numbers as keys which
 *     is my case as entities are just a number. \
 * \
 * Lets imagine this case. Here we have a sparse set with all entities having
 *     it's batch at 0, meaning the reference is equal to the id;
 *
 * ![](https://user-images.githubusercontent.com/1812216/89120831-8eea9d00-d4b9-11ea-86fb-a08621cfabc0.png)
 *
 * We have a **sparse array [2, -, 0, -, -, -, 3, 1]** and a **packed array
 *     [2, 7, 0, 6]**. The *indices* in the **sparse array** are the ***keys***
 *     to access the ***values*** in the **packed arrray**. The **sparse array**
 *     *indicies* correspond to the entity's *id*. Let's say we want to get the
 *     value for the *entity 6* (remember, all these entities in this example
 *     have it's `batch at 0`). We get the ***id*** of this entity, which is `6`
 *     as well, and access the **sparse array** with it. The value at index `6`
 *     of the **sparse array** is `3` which corresponds to the **packed array
 *     index** we must access to retrieve the **value** for this entity. At the
 *     index `3` of the **packed array** we have the value we were looking for
 *     `6`. \
 * \
 * Why is the **value** the same number as the **entity's reference**? In this
 *     SparseSet class we store the references of the entities in the packed
 *     array. This way we know which ones exist. \
 * \
 * Let's say we ask *`give me all entities contained in this SparseSet`*. We can
 *     just return the **packed array**. Let's say we ask *`does this SparseSet
 *     contain this entity?`* Now we just access the **sparse array** with the
 *     entity's id, then access the **packed array** with the value found and
 *     compare both references, if they match, then the reference exists in the
 *     SparseSet. Something like this\:
 *
 * ```d
 * packed[sparse[entity_id]] == entity;
 * ```
 *
 * Obviously this SparseSet class by itself doesn't have much value in
 *     in our case. However, when we blend this with the **Pool** class which
 *     stores all individual components, we make wonders.
 *
 * Params:
 *     T = a valid EntityType.
 *     idBitAmount = a valid number of bits reserved for the id.
 *
 * See_Also: $(REF Pool, ecs.pool)
 */
@safe pure
package class SparseSet(T, T idBitAmount)
	if (isEntityType!T && isValidBitIdAmount!(T, idBitAmount))
{
	import ecs.registry : BasicRegistry;

public:
	/**
	 * Check if an entity exists in the sparse set. \
	 * An entity exists if, with all the safe checks made, the following is true\:
	 *
	 * ```d
	 * packedEntities[entities[idOf(entity)]] == entity
	 * ```
	 *
	 * Params: entity = reference, valid or not, to validate.
	 *
	 * Returns: `true` if exists, `false` otherwise
	 *
	 * See_Also: $(LREF canAcess)
	 */
	@safe pure
	bool contains(const inout(T) entity) const inout
	{
		return canAccess(entity)
			&& entities[idOf(entity)] < packedEntities.length
			&& packedEntities[entities[idOf(entity)]] == entity;
	}


protected:
	/**
	 * Check if an entity's reference can be accessed in the sparse array. \
	 * If the extracted id from the entity is lower than the sparse array's
	 *     length, the entity was never inserted in the current sparse set. If
	 *     it is lower, there is chance it might've.
	 *
	 * Params: entity = reference which extracted id is going to be evaluated.
	 *
	 * Returns: `true` if the entity's id is lower than the sparse array's
	 *     length, `false` otherwise.
	 *
	 * See_Also: $(LREF contains)
	 */
	@safe pure
	bool canAccess(const inout(T) entity) const inout
	{
		return idOf(entity) < entities.length;
	}


	/**
	 * Inserts an entity in the sparse set. \
	 * A new entity, when inserted, is pushed at the back of the packed array.
	 *     Then it's last index, or it's length before the entity was pushed in,
	 *     is inserted in the sparse array at the position where it's index is
	 *     equal to the entity's id. Something like this\:
	 *
	 * ```d
	 * immutable pos = packedEntities.length;
	 * packedEntities.insertBack(entity);
	 * entities[idOf(entity)] = pos;
	 * ```
	 *
	 * Params: entity = valid entity which is going to be inserted
	 */
	@safe pure
	void add(const inout(T) entity)
		in (!contains(entity))
	{
		const eid = idOf(entity);
		const T pos = cast(T)(packedEntities.length);

		packedEntities ~= entity;

		if (eid >= entities.length)
		{
			entities.length = eid + 1;
		}

		entities[eid] = pos;
	}


	/**
	 * Removes an entity from the sparse set. \
	 * When removing an entity from the sparse set we don't just simply remove
	 *     it at it's index, that would be ineficient as it would either leave
	 *     gaps in the packed array or it would return a new array with gaps
	 *     making it very hard to keep in sync with the sparse array. \
	 * \
	 * To go around such a problem, before we remove the entity we swap it with
	 *     the last entity of the array, update the new positions in the sparse
	 *     array, and then remove the last element of the packed array only. How
	 *     about the last element of the sparse array? We just don't need to
	 *     remove it! \
	 * \
	 * Imagine this case, we have a **sparse array [2, -, 0, -, -, -, 3, 1]**
	 *     and a **packed array [2, 7, 0, 6]**. We delete the entity with id 7,
	 *     to simplify all the entities in this example have it's batch at 0, so
	 *     it's reference is 7 as well.
	 *
	 * ![](https://user-images.githubusercontent.com/1812216/89120832-8f833380-d4b9-11ea-9d5f-c798c89c64c7.png)
	 *
	 * As you can see, we swapped the last elemen, entity 6, in the sparse array
	 *     with the element which used to be refering to entity 7 and update the
	 *     sparse array to point to the right place at index 6. Something like
	 *     this\:
	 *
	 * ```d
	 * immutable back = packedEntities.back;
	 * swap(packedEntities.back, packedEntities[entities[idOf(entity)]]);
	 * swap(entities[idOf(back)], entities[idOf(entity)]);
	 * packedEntities.removeBack();
	 * ```
	 *
	 * We don't remove the element in the sparse array because it is useless to
	 *     do it. We know if an entity is valid if
	 *     `packedEntities[entities[idOf(entity)]] == entity`, knowing this, it
	 *     becomes useless to remove the element as this check will fail anyway.
	 *
	 * Params: entity = valid entity to remove.
	 */
	@safe pure
	void remove(const inout(T) entity)
		in (contains(entity))
	{
		import std.algorithm : swap;
		import std.range : back, popBack;
		const eid = idOf(entity);
		const last = packedEntities.back;

		swap(packedEntities.back, packedEntities[entities[eid]]);
		swap(entities[idOf(last)], entities[eid]);

		packedEntities.popBack();
	}


	/**
	 * Get the id of any valid or invalid entity's reference.
	 *
	 * Params: entity = reference from which the id is going to be extracted.
	 *
	 * Returns: the entity's id
	 */
	@safe pure
	inout(T) idOf(const inout(T) entity) const inout
	{
		return entity & BasicRegistry!(T, idBitAmount).entityMask;
	}


	T[] entities;
	T[] packedEntities;
}


@system pure
@("sparseset: add")
unittest
{
	import std.array : array;
	import core.exception : AssertError;
	import std.exception : assertThrown;

	SparseSet!(uint, 20) ss = new SparseSet!(uint, 20);
	const uint e0 = 0; // simulates an entity with id(0) and batch(0)
	const uint e6 = 6; // simulates an entity with id(6) and batch(0)

	assertEquals(0, ss.entities.length);
	assertEquals(0, ss.packedEntities.length);

	ss.add(e0);
	assertEquals(1, ss.entities.length);
	assertEquals(1, ss.packedEntities.length);

	// in this case we can use the entity directly because we know the batch is 0
	// but internaly only the id of the entity is used as an index
	assertSame(e0, ss.packedEntities[ss.entities[e0]]);

	ss.add(e6);
	assertEquals(e6 + 1, ss.entities.length);
	assertEquals(2, ss.packedEntities.length);

	uint[] arr;
	arr.length = e6 - 1; // simulate the space between e0 and e6 in ss.entities
	assertEquals(arr, ss.entities[e0 + 1 .. e6].array);

	assertSame(e6, ss.packedEntities[ss.entities[e6]]);

	assertThrown!AssertError(ss.add(e0));

	const uint e01 = (1 << 20) | 0; // simulates an entity with id(0) and batch(1)
	ss.add(e01); // same id but diferent batch so it adds

	// now it creates a problem, the new entity was placed at the end of the packedEntities
	// however it's id is the same as e0 and e0 was not removed!
	// if you now remove e0 from this pool this will remove e01 from packedEntities
	// this example will not happen in the actual world because this tested in registry
	// and at this point e0 was already discarded and removed from this pool
	assertEquals(e6 + 1, ss.entities.length);
	assertEquals(3, ss.packedEntities.length);
}


@safe pure
@("sparseset: contains")
unittest
{
	SparseSet!(uint, 20) ss = new SparseSet!(uint, 20);
	const uint e0 = 0; // simulates an entity with id(0) and batch(0)
	const uint e6 = 6; // simulates an entity with id(6) and batch(0)
	const uint e61 = (1 << 20) | 6; // simulates an entity with id(6) and batch(1)

	assertFalse(ss.contains(e0));

	ss.add(e6);

	assertTrue(ss.contains(e6));
	assertFalse(ss.contains(e61));
	assertFalse(ss.contains(e0));
}


@safe pure
@("sparseset: canAccess")
unittest
{
	SparseSet!(uint, 20) ss = new SparseSet!(uint, 20);
	const uint e0 = 0; // simulates an entity with id(0) and batch(0)
	const uint e6 = 6; // simulates an entity with id(6) and batch(0)
	const uint e61 = (1 << 20) | 6; // simulates an entity with id(6) and batch(1)

	assertFalse(ss.canAccess(e6));

	ss.add(e6);

	assertTrue(ss.canAccess(e6));
	assertTrue(ss.canAccess(e61));
	assertTrue(ss.canAccess(e0));
}


@system pure
@("sparseset: remove")
unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	SparseSet!(uint, 20) ss = new SparseSet!(uint, 20);
	const uint e0 = 0; // simulates an entity with id(0) and batch(0)
	const uint e6 = 6; // simulates an entity with id(6) and batch(0)
	const uint e61 = (1 << 20) | 6; // simulates an entity with id(6) and batch(1)

	ss.add(e6);
	ss.add(e0);

	assertSame(e6, ss.packedEntities[0]);
	assertSame(e0, ss.packedEntities[1]);

	assertThrown!AssertError(ss.remove(e61));

	// simulate the discard of e6
	ss.remove(e6);

	assertSame(e0, ss.packedEntities[0]);
	ss.add(e61);

	assertSame(e0, ss.packedEntities[0]);
	assertSame(e61, ss.packedEntities[1]);
}


@safe pure
@("sparseset: idOf")
unittest
{
	SparseSet!(uint, 20) ss = new SparseSet!(uint, 20);
	const uint e0 = 0; // simulates an entity with id(0) and batch(0)
	const uint e6 = 6; // simulates an entity with id(6) and batch(0)
	const uint e61 = (1 << 20) | 6; // simulates an entity with id(6) and batch(1)

	assertEquals(0, ss.idOf(e0));
	assertEquals(6, ss.idOf(e6));
	assertEquals(6, ss.idOf(e61));
}
